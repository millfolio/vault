"""WebAuthn test — proves the ES256/WebAuthn assertion path is correct.

Builds + runs as a plain Mojo program: `pixi run test-webauthn`. The signature
verification touches OpenSSL `libcrypto` over FFI (the ECDSA_do_verify path), so
this must run inside the pixi env (flare-ffi has populated `$CONDA_PREFIX/lib`).

## Test vector

A self-consistent WebAuthn `get` assertion generated locally with OpenSSL
(`scripts` / scratchpad `gen.py`) and independently verified by
`openssl dgst -sha256 -verify` before being frozen here. It exercises the FULL
pipeline against rpId `localhost` / origin `http://localhost:10000`:

  * public key    P-256 (X, Y) below (also embedded in the SPKI DER blob)
  * challenge      32 bytes 0x00..0x1f  → base64url `AAECAw…Hh8`
  * authData       rpIdHash(SHA-256("localhost")) ‖ flags 0x05 (UP|UV) ‖ count 5
  * clientDataJSON {"type":"webauthn.get","challenge":…,"origin":…,"crossOrigin":false}
  * signature      DER ECDSA-SHA256 over authData ‖ SHA-256(clientDataJSON)

`rpIdHash` 49960de5… is the well-known SHA-256("localhost").
"""

from webauthn import (
    base64url_encode,
    base64url_decode,
    bytes_to_hex,
    hex_to_bytes,
    sha256_raw,
    parse_auth_data,
    check_client_data,
    pubkey_from_spki,
    verify_es256,
    verify_assertion,
    save_enrollment,
    load_enrollment,
    Enrollment,
    random_bytes,
    new_challenge_b64u,
)
from std.os import getenv


# ── frozen vector ────────────────────────────────────────────────────────────
comptime PUB_X = (
    "4607968307004f4526f7f2e6c596efb7ef5d45e42f43e2d5e6130ecab235c8a9"
)
comptime PUB_Y = (
    "275080c0fd65b0ab3603507caaf615c2cf5a899cdf2ce41e698a567ee66ab4e2"
)
comptime SPKI = "3059301306072a8648ce3d020106082a8648ce3d030107034200044607968307004f4526f7f2e6c596efb7ef5d45e42f43e2d5e6130ecab235c8a9275080c0fd65b0ab3603507caaf615c2cf5a899cdf2ce41e698a567ee66ab4e2"
comptime AUTH_DATA_B64U = "SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MFAAAABQ"
comptime CLIENT_DATA_B64U = "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiQUFFQ0F3UUZCZ2NJQ1FvTERBME9EeEFSRWhNVUZSWVhHQmthR3h3ZEhoOCIsIm9yaWdpbiI6Imh0dHA6Ly9sb2NhbGhvc3Q6MTAwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9"
comptime SIG_B64U = "MEUCIQDl5BGuh3eRrW9q5RHQAFoN8TsziInD73wCqyYCXFc0QQIgFkSFpRGEjn-lzVSziDaBX8iAKk4n99UhNR_2AahnYp0"
comptime CHALLENGE_B64U = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
comptime ORIGIN = "http://localhost:10000"
comptime RP_ID = "localhost"


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _signed_message() raises -> List[UInt8]:
    """authData ‖ SHA-256(clientDataJSON) — what ES256 actually signs."""
    var ad = base64url_decode(String(AUTH_DATA_B64U))
    var cdj = base64url_decode(String(CLIENT_DATA_B64U))
    var h = sha256_raw(cdj)
    var msg = ad.copy()
    for i in range(len(h)):
        msg.append(h[i])
    return msg^


def main() raises:
    # ── base64url roundtrip ─────────────────────────────────────────────────
    var raw: List[UInt8] = [0, 1, 2, 250, 251, 252, 253, 254, 255]
    expect(
        bytes_to_hex(base64url_decode(base64url_encode(raw)))
        == bytes_to_hex(raw),
        "base64url roundtrip",
    )
    # No padding, URL-safe alphabet.
    expect(base64url_encode([255, 255, 255]) == "____", "b64url ffffff")

    # ── hex roundtrip ───────────────────────────────────────────────────────
    expect(
        bytes_to_hex(hex_to_bytes(String(PUB_X))) == String(PUB_X),
        "hex roundtrip",
    )

    # ── SHA-256 known vectors ───────────────────────────────────────────────
    var abc: List[UInt8] = [97, 98, 99]  # "abc"
    expect(
        bytes_to_hex(sha256_raw(abc))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256(abc)",
    )
    expect(
        bytes_to_hex(sha256_raw(List[UInt8]()))
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "SHA-256(empty)",
    )

    # ── authenticatorData parse ─────────────────────────────────────────────
    var ad = parse_auth_data(base64url_decode(String(AUTH_DATA_B64U)))
    expect(ad.user_present(), "UP flag set")
    expect(ad.user_verified(), "UV flag set (Touch-ID proof)")
    expect(Int(ad.sign_count) == 5, "signCount == 5")
    expect(
        bytes_to_hex(ad.rp_id_hash)
        == "49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d9763",
        "rpIdHash == SHA-256(localhost)",
    )

    # ── clientDataJSON checks ───────────────────────────────────────────────
    var cdj = base64url_decode(String(CLIENT_DATA_B64U))
    check_client_data(cdj, String(CHALLENGE_B64U), String(ORIGIN))  # ok
    var replayed = False
    try:
        check_client_data(cdj, "d3JvbmdjaGFsbGVuZ2U", String(ORIGIN))
    except:
        replayed = True
    expect(replayed, "wrong challenge rejected (replay guard)")
    var badorigin = False
    try:
        check_client_data(cdj, String(CHALLENGE_B64U), "http://evil.example")
    except:
        badorigin = True
    expect(badorigin, "wrong origin rejected")

    # ── SPKI → (X, Y) ───────────────────────────────────────────────────────
    var xy = pubkey_from_spki(hex_to_bytes(String(SPKI)))
    expect(bytes_to_hex(xy[0]) == String(PUB_X), "SPKI X matches")
    expect(bytes_to_hex(xy[1]) == String(PUB_Y), "SPKI Y matches")

    # ── ES256 verify: valid ─────────────────────────────────────────────────
    var x = hex_to_bytes(String(PUB_X))
    var y = hex_to_bytes(String(PUB_Y))
    var msg = _signed_message()
    var sig = base64url_decode(String(SIG_B64U))
    expect(
        verify_es256(x, y, msg, sig), "ECDSA verify (good signature) == True"
    )

    # ── ES256 verify: tampered signature (flip last DER byte) ───────────────
    var bad_sig = sig.copy()
    bad_sig[len(bad_sig) - 1] = bad_sig[len(bad_sig) - 1] ^ 0x01
    expect(
        not verify_es256(x, y, msg, bad_sig),
        "ECDSA verify (tampered signature) == False",
    )

    # ── ES256 verify: tampered message ──────────────────────────────────────
    var bad_msg = msg.copy()
    bad_msg[0] = bad_msg[0] ^ 0x01
    expect(
        not verify_es256(x, y, bad_msg, sig),
        "ECDSA verify (tampered message) == False",
    )

    # ── ES256 verify: wrong public key (flip a byte of X) ───────────────────
    var bad_x = x.copy()
    bad_x[0] = bad_x[0] ^ 0x01
    var wrongkey: Bool
    try:
        # May raise (point off curve) OR return False — both are a rejection.
        wrongkey = not verify_es256(bad_x, y, msg, sig)
    except:
        wrongkey = True
    expect(wrongkey, "ECDSA verify (wrong pubkey) rejected")

    # ── full assertion: end-to-end success ──────────────────────────────────
    var new_count = verify_assertion(
        String(AUTH_DATA_B64U),
        String(CLIENT_DATA_B64U),
        String(SIG_B64U),
        x,
        y,
        String(CHALLENGE_B64U),
        String(ORIGIN),
        String(RP_ID),
        stored_sign_count=UInt32(4),  # last seen 4; assertion carries 5
    )
    expect(Int(new_count) == 5, "verify_assertion returns new signCount 5")

    # ── full assertion: signCount replay (stored already 5) rejected ────────
    var clone = False
    try:
        _ = verify_assertion(
            String(AUTH_DATA_B64U),
            String(CLIENT_DATA_B64U),
            String(SIG_B64U),
            x,
            y,
            String(CHALLENGE_B64U),
            String(ORIGIN),
            String(RP_ID),
            stored_sign_count=UInt32(5),
        )
    except:
        clone = True
    expect(clone, "assertion with non-increasing signCount rejected")

    # ── full assertion: UV required but cleared → rejected ──────────────────
    var ad_bytes = base64url_decode(String(AUTH_DATA_B64U))
    ad_bytes[32] = ad_bytes[32] & ~UInt8(0x04)  # clear UV bit
    var no_uv = base64url_encode(ad_bytes)
    var uv_rejected = False
    try:
        _ = verify_assertion(
            no_uv,
            String(CLIENT_DATA_B64U),
            String(SIG_B64U),
            x,
            y,
            String(CHALLENGE_B64U),
            String(ORIGIN),
            String(RP_ID),
            stored_sign_count=UInt32(4),
        )
    except:
        uv_rejected = True
    expect(uv_rejected, "assertion without UV rejected when require_uv")

    # ── full assertion: wrong challenge → rejected ──────────────────────────
    var chal_rejected = False
    try:
        _ = verify_assertion(
            String(AUTH_DATA_B64U),
            String(CLIENT_DATA_B64U),
            String(SIG_B64U),
            x,
            y,
            "c29tZW90aGVyY2hhbGxlbmdl",
            String(ORIGIN),
            String(RP_ID),
            stored_sign_count=UInt32(4),
        )
    except:
        chal_rejected = True
    expect(chal_rejected, "assertion with wrong challenge rejected")

    # ── enrollment storage roundtrip ────────────────────────────────────────
    var dir = getenv("MILLFOLIO_DATA_DIR", "/tmp")
    var e = Enrollment("cred-abc", x.copy(), y.copy(), UInt32(5))
    save_enrollment(dir, e)
    var loaded = load_enrollment(dir)
    expect(
        loaded.credential_id == "cred-abc", "enrollment credentialId roundtrip"
    )
    expect(
        bytes_to_hex(loaded.pub_x) == String(PUB_X), "enrollment X roundtrip"
    )
    expect(Int(loaded.sign_count) == 5, "enrollment signCount roundtrip")

    # ── randomness: 32-byte, distinct challenges ────────────────────────────
    expect(len(random_bytes(32)) == 32, "random_bytes(32) length")
    expect(
        new_challenge_b64u() != new_challenge_b64u(),
        "challenges are distinct (CSPRNG)",
    )

    print("ok: all webauthn tests passed")
