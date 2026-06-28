"""sha256 — a pure-Mojo SHA-256 over bytes.

Used to content-hash each vault file so `mill index` can skip files whose bytes
haven't changed since the last index (incremental re-index). Local-only: the
digest is a change-detection key, never sent to the frontier model.

`sha256_hex(bytes)` returns the lowercase 64-char hex digest. Verified against
the FIPS-180-4 test vector sha256("abc").
"""


def _k_table() -> List[UInt32]:
    """The 64 SHA-256 round constants (cube-root fractions)."""
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


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (UInt32(32) - n))


def sha256_hex(data: List[UInt8]) -> String:
    """Lowercase 64-char hex SHA-256 digest of `data`."""
    var h0 = UInt32(0x6A09E667)
    var h1 = UInt32(0xBB67AE85)
    var h2 = UInt32(0x3C6EF372)
    var h3 = UInt32(0xA54FF53A)
    var h4 = UInt32(0x510E527F)
    var h5 = UInt32(0x9B05688C)
    var h6 = UInt32(0x1F83D9AB)
    var h7 = UInt32(0x5BE0CD19)

    # Pad: append 0x80, then 0x00 until length ≡ 56 (mod 64), then the 64-bit
    # big-endian bit length.
    var bitlen = UInt64(len(data)) * 8
    var msg = data.copy()
    msg.append(UInt8(0x80))
    while len(msg) % 64 != 56:
        msg.append(UInt8(0))
    for i in range(8):
        msg.append(
            UInt8((bitlen >> (UInt64(56) - UInt64(8) * UInt64(i))) & 0xFF)
        )

    var kt = _k_table()
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

    var digest = List[UInt32]()
    digest.append(h0)
    digest.append(h1)
    digest.append(h2)
    digest.append(h3)
    digest.append(h4)
    digest.append(h5)
    digest.append(h6)
    digest.append(h7)
    comptime hexd = "0123456789abcdef"
    var out = String("")
    for i in range(8):
        var v = digest[i]
        for shift in range(28, -4, -4):
            var nib = Int((v >> UInt32(shift)) & 0xF)
            out += hexd[nib]
    return out^


def sha256_file_hex(path: String) raises -> String:
    """SHA-256 of a file's raw bytes (lowercase hex). Reads in BINARY mode
    (`read_bytes`) — files may be non-UTF-8 (e.g. PDFs), so a text `read()` would
    raise 'invalid UTF-8'."""
    var data = List[UInt8]()
    with open(path, "r") as f:
        var b = f.read_bytes()
        for i in range(len(b)):
            data.append(b[i])
    return sha256_hex(data)
