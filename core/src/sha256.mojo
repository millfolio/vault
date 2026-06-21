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
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    return k^


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (UInt32(32) - n))


def sha256_hex(data: List[UInt8]) -> String:
    """Lowercase 64-char hex SHA-256 digest of `data`."""
    var h0 = UInt32(0x6a09e667)
    var h1 = UInt32(0xbb67ae85)
    var h2 = UInt32(0x3c6ef372)
    var h3 = UInt32(0xa54ff53a)
    var h4 = UInt32(0x510e527f)
    var h5 = UInt32(0x9b05688c)
    var h6 = UInt32(0x1f83d9ab)
    var h7 = UInt32(0x5be0cd19)

    # Pad: append 0x80, then 0x00 until length ≡ 56 (mod 64), then the 64-bit
    # big-endian bit length.
    var bitlen = UInt64(len(data)) * 8
    var msg = data.copy()
    msg.append(UInt8(0x80))
    while len(msg) % 64 != 56:
        msg.append(UInt8(0))
    for i in range(8):
        msg.append(UInt8((bitlen >> (UInt64(56) - UInt64(8) * UInt64(i))) & 0xFF))

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
            var s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> UInt32(3))
            var s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> UInt32(10))
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
    digest.append(h0); digest.append(h1); digest.append(h2); digest.append(h3)
    digest.append(h4); digest.append(h5); digest.append(h6); digest.append(h7)
    comptime hexd = "0123456789abcdef"
    var out = String("")
    for i in range(8):
        var v = digest[i]
        for shift in range(28, -4, -4):
            var nib = Int((v >> UInt32(shift)) & 0xF)
            out += hexd[nib]
    return out^


def sha256_file_hex(path: String) raises -> String:
    """SHA-256 of a file's raw bytes (lowercase hex). Reads the whole file."""
    var bytes: List[UInt8]
    with open(path, "r") as f:
        var s = f.read()
        bytes = List[UInt8](s.as_bytes())
    return sha256_hex(bytes)
