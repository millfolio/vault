"""WebAuthn — server-side cryptographic verification of a WebAuthn (Touch-ID)
assertion, so the "reveal transaction amounts" gate is *enforced* by the Mojo
server rather than trusted from a client-side screen.

## Why this exists

`GET /api/transactions?amounts=1` hands the browser the real figures. Today the
`?amounts=1` flag is set by the client AFTER a local Touch-ID prompt — but the
server does no checking, so anyone who calls the endpoint with the flag gets the
amounts. This module lets the server require a *verified* WebAuthn assertion
(`webauthn.get`) — the platform authenticator's ECDSA signature over the
challenge — before it will mint the bearer token that unlocks amounts.

## The crypto path (feasibility-confirmed)

ES256 (ECDSA over NIST P-256 / secp256r1, SHA-256) is reachable from Mojo via
the OpenSSL 3 `libcrypto` that flare already links (`$CONDA_PREFIX/lib/
libcrypto.dylib`). We dlopen it and call, over the C ABI:

    EC_KEY_new_by_curve_name(NID_X9_62_prime256v1=415)
    BN_bin2bn(x,32,NULL) / BN_bin2bn(y,32,NULL)
    EC_KEY_set_public_key_affine_coordinates(key, bx, by)   # validates on-curve
    d2i_ECDSA_SIG(NULL, &der, len)                           # parse DER (r,s)
    ECDSA_do_verify(digest32, 32, sig, key)                 # 1 = valid

The signed message per the WebAuthn spec is `authenticatorData ‖
SHA-256(clientDataJSON)`; ES256 signs `SHA-256(message)`, so we hand
`ECDSA_do_verify` the pre-computed `SHA-256(authData ‖ SHA-256(cdj))`. Both
SHA-256s are pure-Mojo here (no lib needed for hashing) — only the final ECDSA
step touches `libcrypto`.

SHA-256 mirrors `vault/core .../index/sha256.mojo` but emits the raw 32-byte
digest (that module only exposes hex). base64url is implemented locally (RFC
4648 §5, no padding) to keep the module free of a flare import.

## Enrollment format (no CBOR/COSE)

To avoid parsing the CBOR `attestationObject`, the browser sends the public key
straight from `PublicKeyCredential.response.getPublicKey()` — a SPKI DER blob.
For P-256 that blob is a fixed 91 bytes: a 26-byte prefix, `0x04`, then X(32) ‖
Y(32). `pubkey_from_spki` validates the prefix and slices out (X, Y). Clients
that already hold the raw coordinates may send them directly.
"""

from std.ffi import c_int, OwnedDLHandle
from std.os import getenv
from std.os.path import exists
from json import loads


# ─────────────────────────────────────────────────────────────────────────────
# base64url (RFC 4648 §5, no padding). Tolerates trailing '=' and the standard
# '+'/'/' alphabet on decode so callers can be lenient.
# ─────────────────────────────────────────────────────────────────────────────


def _b64_alphabet() -> StaticString:
    return "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def base64url_encode(data: List[UInt8]) -> String:
    """Encode bytes as URL-safe base64 (alphabet `A-Za-z0-9-_`, no padding)."""
    var alpha = _b64_alphabet().unsafe_ptr()
    var n = len(data)
    if n == 0:
        return ""
    var out = List[UInt8]()
    out.reserve((n * 4 + 2) // 3)
    var src = data.unsafe_ptr()
    var i = 0
    while i + 3 <= n:
        var b0 = Int(src[i])
        var b1 = Int(src[i + 1])
        var b2 = Int(src[i + 2])
        out.append(alpha[(b0 >> 2) & 63])
        out.append(alpha[((b0 << 4) | (b1 >> 4)) & 63])
        out.append(alpha[((b1 << 2) | (b2 >> 6)) & 63])
        out.append(alpha[b2 & 63])
        i += 3
    var rem = n - i
    if rem == 1:
        var b0 = Int(src[i])
        out.append(alpha[(b0 >> 2) & 63])
        out.append(alpha[(b0 << 4) & 63])
    elif rem == 2:
        var b0 = Int(src[i])
        var b1 = Int(src[i + 1])
        out.append(alpha[(b0 >> 2) & 63])
        out.append(alpha[((b0 << 4) | (b1 >> 4)) & 63])
        out.append(alpha[(b1 << 2) & 63])
    return String(unsafe_from_utf8=Span[UInt8, _](out))


@always_inline
def _b64_decode_byte(c: UInt8) raises -> Int:
    if c >= 65 and c <= 90:
        return Int(c) - 65
    if c >= 97 and c <= 122:
        return Int(c) - 97 + 26
    if c >= 48 and c <= 57:
        return Int(c) - 48 + 52
    if c == 45 or c == 43:  # '-' or '+'
        return 62
    if c == 95 or c == 47:  # '_' or '/'
        return 63
    raise Error("base64url_decode: invalid character")


def base64url_decode(s: String) raises -> List[UInt8]:
    """Decode URL-safe base64 (with or without trailing `=`)."""
    var n = s.byte_length()
    var src = s.unsafe_ptr()
    while n > 0 and src[n - 1] == 61:  # strip '='
        n -= 1
    if n == 0:
        return List[UInt8]()
    if n % 4 == 1:
        raise Error("base64url_decode: invalid length")
    var out = List[UInt8]()
    out.reserve((n * 3) // 4)
    var i = 0
    while i + 4 <= n:
        var b0 = _b64_decode_byte(src[i])
        var b1 = _b64_decode_byte(src[i + 1])
        var b2 = _b64_decode_byte(src[i + 2])
        var b3 = _b64_decode_byte(src[i + 3])
        out.append(UInt8(((b0 << 2) | (b1 >> 4)) & 255))
        out.append(UInt8(((b1 << 4) | (b2 >> 2)) & 255))
        out.append(UInt8(((b2 << 6) | b3) & 255))
        i += 4
    var rem = n - i
    if rem == 2:
        var b0 = _b64_decode_byte(src[i])
        var b1 = _b64_decode_byte(src[i + 1])
        out.append(UInt8(((b0 << 2) | (b1 >> 4)) & 255))
    elif rem == 3:
        var b0 = _b64_decode_byte(src[i])
        var b1 = _b64_decode_byte(src[i + 1])
        var b2 = _b64_decode_byte(src[i + 2])
        out.append(UInt8(((b0 << 2) | (b1 >> 4)) & 255))
        out.append(UInt8(((b1 << 4) | (b2 >> 2)) & 255))
    return out^


# ─────────────────────────────────────────────────────────────────────────────
# hex helpers (public keys are persisted as hex in webauthn.json)
# ─────────────────────────────────────────────────────────────────────────────


def bytes_to_hex(data: List[UInt8]) -> String:
    comptime hexd = "0123456789abcdef"
    var out = String("")
    for i in range(len(data)):
        var v = Int(data[i])
        out += hexd[(v >> 4) & 0xF]
        out += hexd[v & 0xF]
    return out^


@always_inline
def _hex_nib(c: UInt8) raises -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 97 + 10
    if c >= 65 and c <= 70:
        return Int(c) - 65 + 10
    raise Error("hex_to_bytes: invalid character")


def hex_to_bytes(s: String) raises -> List[UInt8]:
    var n = s.byte_length()
    if n % 2 != 0:
        raise Error("hex_to_bytes: odd length")
    var src = s.unsafe_ptr()
    var out = List[UInt8]()
    out.reserve(n // 2)
    var i = 0
    while i < n:
        var hi = _hex_nib(src[i])
        var lo = _hex_nib(src[i + 1])
        out.append(UInt8((hi << 4) | lo))
        i += 2
    return out^


# ─────────────────────────────────────────────────────────────────────────────
# SHA-256 → raw 32-byte digest (pure Mojo; FIPS-180-4). Adapted from
# vault/core .../index/sha256.mojo which only exposes the hex form.
# ─────────────────────────────────────────────────────────────────────────────


def _sha_k() -> List[UInt32]:
    var k: List[UInt32] = [
        0x428A2F98,
        0x71374491,
        0xB5C0FBCF,
        0xE9B5DBA5,
        0x3956C25B,
        0x59F111F1,
        0x923F82A4,
        0xAB1C5ED5,
        0xD807AA98,
        0x12835B01,
        0x243185BE,
        0x550C7DC3,
        0x72BE5D74,
        0x80DEB1FE,
        0x9BDC06A7,
        0xC19BF174,
        0xE49B69C1,
        0xEFBE4786,
        0x0FC19DC6,
        0x240CA1CC,
        0x2DE92C6F,
        0x4A7484AA,
        0x5CB0A9DC,
        0x76F988DA,
        0x983E5152,
        0xA831C66D,
        0xB00327C8,
        0xBF597FC7,
        0xC6E00BF3,
        0xD5A79147,
        0x06CA6351,
        0x14292967,
        0x27B70A85,
        0x2E1B2138,
        0x4D2C6DFC,
        0x53380D13,
        0x650A7354,
        0x766A0ABB,
        0x81C2C92E,
        0x92722C85,
        0xA2BFE8A1,
        0xA81A664B,
        0xC24B8B70,
        0xC76C51A3,
        0xD192E819,
        0xD6990624,
        0xF40E3585,
        0x106AA070,
        0x19A4C116,
        0x1E376C08,
        0x2748774C,
        0x34B0BCB5,
        0x391C0CB3,
        0x4ED8AA4A,
        0x5B9CCA4F,
        0x682E6FF3,
        0x748F82EE,
        0x78A5636F,
        0x84C87814,
        0x8CC70208,
        0x90BEFFFA,
        0xA4506CEB,
        0xBEF9A3F7,
        0xC67178F2,
    ]
    return k^


@always_inline
def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (UInt32(32) - n))


def sha256_raw(data: List[UInt8]) -> List[UInt8]:
    """Raw 32-byte SHA-256 digest of `data`."""
    var h0 = UInt32(0x6A09E667)
    var h1 = UInt32(0xBB67AE85)
    var h2 = UInt32(0x3C6EF372)
    var h3 = UInt32(0xA54FF53A)
    var h4 = UInt32(0x510E527F)
    var h5 = UInt32(0x9B05688C)
    var h6 = UInt32(0x1F83D9AB)
    var h7 = UInt32(0x5BE0CD19)

    var bitlen = UInt64(len(data)) * 8
    var msg = data.copy()
    msg.append(UInt8(0x80))
    while len(msg) % 64 != 56:
        msg.append(UInt8(0))
    for i in range(8):
        msg.append(
            UInt8((bitlen >> (UInt64(56) - UInt64(8) * UInt64(i))) & 0xFF)
        )

    var kt = _sha_k()
    var w = InlineArray[UInt32, 64](fill=UInt32(0))
    var nblocks = len(msg) // 64
    for b in range(nblocks):
        var base = b * 64
        for t in range(16):
            var j = base + t * 4
            w[t] = (
                (UInt32(Int(msg[j])) << 24)
                | (UInt32(Int(msg[j + 1])) << 16)
                | (UInt32(Int(msg[j + 2])) << 8)
                | UInt32(Int(msg[j + 3]))
            )
        for t in range(16, 64):
            var s0 = (
                _rotr(w[t - 15], 7)
                ^ _rotr(w[t - 15], 18)
                ^ (w[t - 15] >> UInt32(3))
            )
            var s1 = (
                _rotr(w[t - 2], 17)
                ^ _rotr(w[t - 2], 19)
                ^ (w[t - 2] >> UInt32(10))
            )
            w[t] = w[t - 16] + s0 + w[t - 7] + s1

        var a = h0
        var b2 = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7
        for t in range(64):
            var S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var ch = (e & f) ^ (~e & g)
            var temp1 = h + S1 + ch + kt[t] + w[t]
            var S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var maj = (a & b2) ^ (a & c) ^ (b2 & c)
            var temp2 = S0 + maj
            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b2
            b2 = a
            a = temp1 + temp2

        h0 += a
        h1 += b2
        h2 += c
        h3 += d
        h4 += e
        h5 += f
        h6 += g
        h7 += h

    var words = [h0, h1, h2, h3, h4, h5, h6, h7]
    var out = List[UInt8]()
    out.reserve(32)
    for i in range(8):
        var v = words[i]
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    return out^


# ─────────────────────────────────────────────────────────────────────────────
# authenticatorData: rpIdHash[32] ‖ flags[1] ‖ signCount[4] ‖ …
# ─────────────────────────────────────────────────────────────────────────────

comptime FLAG_UP = 0x01  # user present
comptime FLAG_UV = 0x04  # user verified (the Touch-ID proof)


@fieldwise_init
struct AuthData(Copyable, Movable):
    var rp_id_hash: List[UInt8]  # 32 bytes
    var flags: Int
    var sign_count: UInt32

    def user_present(self) -> Bool:
        return (self.flags & FLAG_UP) != 0

    def user_verified(self) -> Bool:
        return (self.flags & FLAG_UV) != 0


def parse_auth_data(data: List[UInt8]) raises -> AuthData:
    """Parse the fixed 37-byte prefix of authenticatorData."""
    if len(data) < 37:
        raise Error("authenticatorData too short")
    var rp = List[UInt8]()
    rp.reserve(32)
    for i in range(32):
        rp.append(data[i])
    var flags = Int(data[32])
    var sc = (
        (UInt32(Int(data[33])) << 24)
        | (UInt32(Int(data[34])) << 16)
        | (UInt32(Int(data[35])) << 8)
        | UInt32(Int(data[36]))
    )
    return AuthData(rp^, flags, sc)


# ─────────────────────────────────────────────────────────────────────────────
# clientDataJSON: {"type":"webauthn.get","challenge":<b64url>,"origin":<...>}
# ─────────────────────────────────────────────────────────────────────────────


def check_client_data(
    cdj: List[UInt8], expected_challenge_b64u: String, expected_origin: String
) raises:
    """Validate the clientDataJSON blob against the server's expectations.
    Raises on any mismatch (wrong ceremony type, replayed/absent challenge, or
    an origin that isn't ours)."""
    var text = String(unsafe_from_utf8=Span[UInt8, _](cdj))
    var j = loads(text)
    var typ = j["type"].string_value()
    if typ != "webauthn.get":
        raise Error("clientData.type != webauthn.get (got " + typ + ")")
    var chal = j["challenge"].string_value()
    if chal != expected_challenge_b64u:
        raise Error("clientData.challenge mismatch (replay?)")
    var origin = j["origin"].string_value()
    if origin != expected_origin:
        raise Error("clientData.origin mismatch (got " + origin + ")")


# ─────────────────────────────────────────────────────────────────────────────
# Public key: parse SPKI DER (from getPublicKey()) → (X, Y). P-256 SPKI is a
# fixed 91 bytes: 26-byte prefix ‖ 0x04 ‖ X(32) ‖ Y(32).
# ─────────────────────────────────────────────────────────────────────────────

comptime _P256_SPKI_PREFIX = (
    "3059301306072a8648ce3d020106082a8648ce3d030107034200"
)


def pubkey_from_spki(spki: List[UInt8]) raises -> List[List[UInt8]]:
    """Return `[X, Y]` (32 bytes each) from a P-256 SPKI DER public key."""
    if len(spki) != 91:
        raise Error("SPKI not 91 bytes (not P-256 uncompressed?)")
    var prefix = hex_to_bytes(String(_P256_SPKI_PREFIX))  # 26 bytes
    for i in range(len(prefix)):
        if spki[i] != prefix[i]:
            raise Error("SPKI prefix is not P-256 secp256r1")
    if Int(spki[26]) != 0x04:
        raise Error("SPKI point not uncompressed (0x04)")
    var x = List[UInt8]()
    var y = List[UInt8]()
    for i in range(27, 59):
        x.append(spki[i])
    for i in range(59, 91):
        y.append(spki[i])
    var out = List[List[UInt8]]()
    out.append(x^)
    out.append(y^)
    return out^


# ─────────────────────────────────────────────────────────────────────────────
# ES256 (ECDSA P-256 / SHA-256) verification via OpenSSL libcrypto FFI.
# NID_X9_62_prime256v1 = 415.
# ─────────────────────────────────────────────────────────────────────────────

comptime NID_P256 = 415


def _parse_der_ecdsa_sig(der: List[UInt8]) raises -> List[List[UInt8]]:
    """Extract `[r, s]` big-endian integer bytes from a DER ECDSA signature:
    `SEQUENCE { INTEGER r, INTEGER s }`. Leading 0x00 sign-padding is kept —
    `BN_bin2bn` interprets the bytes as an unsigned big-endian magnitude."""
    var n = len(der)
    if n < 8 or Int(der[0]) != 0x30:
        raise Error("DER sig: not a SEQUENCE")
    var pos = 2  # skip tag + short-form length
    if Int(der[1]) & 0x80 != 0:
        raise Error("DER sig: long-form length unsupported")
    if Int(der[pos]) != 0x02:
        raise Error("DER sig: r not INTEGER")
    var rlen = Int(der[pos + 1])
    pos += 2
    if pos + rlen > n:
        raise Error("DER sig: r overruns")
    var r = List[UInt8]()
    for i in range(pos, pos + rlen):
        r.append(der[i])
    pos += rlen
    if pos + 2 > n or Int(der[pos]) != 0x02:
        raise Error("DER sig: s not INTEGER")
    var slen = Int(der[pos + 1])
    pos += 2
    if pos + slen > n:
        raise Error("DER sig: s overruns")
    var s = List[UInt8]()
    for i in range(pos, pos + slen):
        s.append(der[i])
    var out = List[List[UInt8]]()
    out.append(r^)
    out.append(s^)
    return out^


def _find_libcrypto() raises -> String:
    """Locate the OpenSSL 3 libcrypto flare already links. Under pixi,
    `$CONDA_PREFIX/lib` holds `libcrypto.{dylib,so,so.3}`; otherwise fall back
    to the bare soname so the dynamic loader resolves it from the default path.
    """
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix != "":
        var libdir = prefix + "/lib/"
        var names = ["libcrypto.dylib", "libcrypto.so", "libcrypto.so.3"]
        for i in range(len(names)):
            var cand = libdir + names[i]
            if exists(cand):
                return cand^
    # Loader-resolved fallback (macOS tries .dylib; Linux .so first).
    return "libcrypto.dylib"


def _do_es256_verify(
    read lib: OwnedDLHandle,
    x: List[UInt8],
    y: List[UInt8],
    digest: List[UInt8],
    der_sig: List[UInt8],
) raises -> Bool:
    var f_newkey = lib.get_function[def(c_int) thin abi("C") -> Int](
        "EC_KEY_new_by_curve_name"
    )
    var f_bn = lib.get_function[def(Int, c_int, Int) thin abi("C") -> Int](
        "BN_bin2bn"
    )
    var f_setaff = lib.get_function[def(Int, Int, Int) thin abi("C") -> c_int](
        "EC_KEY_set_public_key_affine_coordinates"
    )
    var f_signew = lib.get_function[def() thin abi("C") -> Int]("ECDSA_SIG_new")
    var f_sigset0 = lib.get_function[def(Int, Int, Int) thin abi("C") -> c_int](
        "ECDSA_SIG_set0"
    )
    var f_verify = lib.get_function[
        def(Int, c_int, Int, Int) thin abi("C") -> c_int
    ]("ECDSA_do_verify")
    var f_ecfree = lib.get_function[def(Int) thin abi("C") -> c_int](
        "EC_KEY_free"
    )
    var f_bnfree = lib.get_function[def(Int) thin abi("C") -> c_int]("BN_free")
    var f_sigfree = lib.get_function[def(Int) thin abi("C") -> c_int](
        "ECDSA_SIG_free"
    )

    var eckey = f_newkey(c_int(NID_P256))
    if eckey == 0:
        raise Error("EC_KEY_new_by_curve_name failed")

    var bx = f_bn(Int(x.unsafe_ptr()), c_int(len(x)), 0)
    var by = f_bn(Int(y.unsafe_ptr()), c_int(len(y)), 0)
    if bx == 0 or by == 0:
        _ = f_ecfree(eckey)
        raise Error("BN_bin2bn failed")

    # Validates the point is on the curve; returns 1 on success.
    var okset = f_setaff(eckey, bx, by)

    # Build ECDSA_SIG from the DER-extracted (r, s). ECDSA_SIG_set0 takes
    # ownership of br/bs (freed by ECDSA_SIG_free), so we don't free them.
    var rs = _parse_der_ecdsa_sig(der_sig)
    var br = f_bn(Int(rs[0].unsafe_ptr()), c_int(len(rs[0])), 0)
    var bs = f_bn(Int(rs[1].unsafe_ptr()), c_int(len(rs[1])), 0)
    var sig = f_signew()
    var okset0 = f_sigset0(sig, br, bs)

    var result = False
    if Int(okset) == 1 and sig != 0 and Int(okset0) == 1:
        var rc = f_verify(
            Int(digest.unsafe_ptr()), c_int(len(digest)), sig, eckey
        )
        result = Int(rc) == 1

    # Anchor the byte buffers past the FFI calls: Mojo's ASAP destruction would
    # otherwise be free to reclaim `digest`/`rs` right after their pointers are
    # read (before the C code dereferences them). Referencing them here keeps
    # the backing memory mapped through the verify.
    _ = len(digest)
    _ = len(rs)
    if sig != 0:
        _ = f_sigfree(sig)  # also frees br/bs (ownership taken by set0)
    _ = f_bnfree(bx)
    _ = f_bnfree(by)
    _ = f_ecfree(eckey)
    return result


def verify_es256(
    x: List[UInt8], y: List[UInt8], message: List[UInt8], der_sig: List[UInt8]
) raises -> Bool:
    """Verify a DER ECDSA-P256 signature over `message` (which is hashed with
    SHA-256 internally, per ES256) against the public key `(X, Y)`.

    Returns True iff the signature is valid. Any structural failure (bad key,
    unparseable DER) raises; a well-formed-but-wrong signature returns False.
    """
    var digest = sha256_raw(message)
    var lib = OwnedDLHandle(_find_libcrypto())
    return _do_es256_verify(lib, x, y, digest, der_sig)


# ─────────────────────────────────────────────────────────────────────────────
# Top-level assertion verification — the whole WebAuthn `get` check.
# ─────────────────────────────────────────────────────────────────────────────


def verify_assertion(
    auth_data_b64u: String,
    client_data_json_b64u: String,
    signature_b64u: String,
    pub_x: List[UInt8],
    pub_y: List[UInt8],
    expected_challenge_b64u: String,
    expected_origin: String,
    expected_rp_id: String,
    stored_sign_count: UInt32,
    require_uv: Bool = True,
) raises -> UInt32:
    """Verify a WebAuthn assertion end-to-end. Returns the new signCount to
    persist on success; raises with a specific reason on any failure.

    Checks, in order: challenge/origin/type (clientDataJSON), rpIdHash ==
    SHA-256(rpId), user-present (+ user-verified when `require_uv`), signCount
    monotonicity (anti-clone), and finally the ECDSA signature over
    `authenticatorData ‖ SHA-256(clientDataJSON)`.
    """
    var auth_data = base64url_decode(auth_data_b64u)
    var cdj = base64url_decode(client_data_json_b64u)
    var sig = base64url_decode(signature_b64u)

    # 1) clientDataJSON — ceremony type, challenge (anti-replay), origin.
    check_client_data(cdj, expected_challenge_b64u, expected_origin)

    # 2) authenticatorData — rpIdHash, flags, signCount.
    var ad = parse_auth_data(auth_data)
    var rp_hash = sha256_raw(_str_to_bytes(expected_rp_id))
    if not _bytes_eq(ad.rp_id_hash, rp_hash):
        raise Error("rpIdHash != SHA-256(rpId)")
    if not ad.user_present():
        raise Error("user-present (UP) flag not set")
    if require_uv and not ad.user_verified():
        raise Error("user-verified (UV) flag not set — no Touch-ID proof")
    # signCount anti-clone: strictly increasing, unless the authenticator
    # doesn't support counters (both zero).
    if not (
        ad.sign_count > stored_sign_count
        or (ad.sign_count == 0 and stored_sign_count == 0)
    ):
        raise Error("signCount did not increase (possible cloned credential)")

    # 3) Signature over authData ‖ SHA-256(clientDataJSON).
    var cdj_hash = sha256_raw(cdj)
    var signed = auth_data.copy()
    for i in range(len(cdj_hash)):
        signed.append(cdj_hash[i])
    if not verify_es256(pub_x, pub_y, signed, sig):
        raise Error("ECDSA signature verification failed")

    return ad.sign_count


def _str_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.unsafe_ptr()
    var n = s.byte_length()
    out.reserve(n)
    for i in range(n):
        out.append(src[i])
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    var diff = 0
    for i in range(len(a)):
        diff |= Int(a[i] ^ b[i])
    return diff == 0


# ─────────────────────────────────────────────────────────────────────────────
# Randomness — 32-byte challenges + bearer tokens from /dev/urandom.
# (Mojo forbids Math.random()/Date.now() in the server context; the CSPRNG is
#  the OS entropy pool.)
# ─────────────────────────────────────────────────────────────────────────────


def random_bytes(n: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    with open("/dev/urandom", "r") as f:
        var b = f.read_bytes(n)
        for i in range(len(b)):
            out.append(b[i])
    if len(out) != n:
        raise Error("random_bytes: short read from /dev/urandom")
    return out^


def new_challenge_b64u() raises -> String:
    """A fresh 32-byte challenge, base64url-encoded (what the client echoes back
    inside clientDataJSON)."""
    return base64url_encode(random_bytes(32))


def new_token() raises -> String:
    """A fresh 32-byte opaque bearer token (base64url)."""
    return base64url_encode(random_bytes(32))


# ─────────────────────────────────────────────────────────────────────────────
# Enrollment storage — webauthn.json in the data dir. One credential for now.
# ─────────────────────────────────────────────────────────────────────────────


@fieldwise_init
struct Enrollment(Copyable, Movable):
    var credential_id: String  # base64url
    var pub_x: List[UInt8]
    var pub_y: List[UInt8]
    var sign_count: UInt32


def _webauthn_path(data_dir: String) -> String:
    return data_dir + "/webauthn.json"


def save_enrollment(data_dir: String, e: Enrollment) raises:
    var s = String("{")
    s += '"credentialId":"' + e.credential_id + '"'
    s += ',"x":"' + bytes_to_hex(e.pub_x) + '"'
    s += ',"y":"' + bytes_to_hex(e.pub_y) + '"'
    s += ',"signCount":' + String(Int(e.sign_count))
    s += "}"
    with open(_webauthn_path(data_dir), "w") as f:
        f.write(s)


def load_enrollment(data_dir: String) raises -> Enrollment:
    var text: String
    with open(_webauthn_path(data_dir), "r") as f:
        text = f.read()
    var j = loads(text)
    var cid = j["credentialId"].string_value()
    var x = hex_to_bytes(j["x"].string_value())
    var y = hex_to_bytes(j["y"].string_value())
    var sc = UInt32(Int(j["signCount"].int_value()))
    return Enrollment(cid, x^, y^, sc)
