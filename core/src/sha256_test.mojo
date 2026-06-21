"""Gate: sha256_hex against FIPS-180-4 known-answer vectors."""

from sha256 import sha256_hex


def _hex_of(s: String) -> String:
    return sha256_hex(List[UInt8](s.as_bytes()))


def main() raises:
    # sha256("") and sha256("abc") — the canonical vectors.
    var empty = _hex_of(String(""))
    var abc = _hex_of(String("abc"))
    print("sha256('')  =", empty)
    print("sha256('abc')=", abc)
    if empty != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855":
        raise Error("empty vector mismatch")
    if abc != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad":
        raise Error("abc vector mismatch")
    # A >1-block message (>55 bytes forces a second padded block).
    var long = _hex_of(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    print("sha256(56-byte)=", long)
    if long != "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1":
        raise Error("56-byte vector mismatch")
    print("OK: sha256 matches all known-answer vectors")
