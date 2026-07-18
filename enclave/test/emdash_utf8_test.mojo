"""UTF-8 poll-stream regression — `run_poll` must preserve raw multi-byte UTF-8.

Guards the "restaurant â▨▨ spending by month" mojibake: the streamed poll path
(`Sandbox.run_poll`, which is where the app server captures the RESULT_SENTINEL
line) used to rebuild the new bytes with a byte-by-byte `chr(Int(b[i]))`, decoding
each UTF-8 byte as its own Latin-1 codepoint and re-encoding it — double-encoding
every multi-byte char (an em-dash's E2 80 94 → C3 A2 C2 80 C2 94, i.e. "â" + two
controls). This test writes a capture file with an em-dash and asserts the polled
line carries the original E2 80 94, never the double-encoded "â". `pixi run
test-emdash`.

NOTE on byte literals: a Mojo `"\xe2"` string escape is a *codepoint* escape
(U+00E2), which UTF-8-encodes to C3 A2 — NOT a raw 0xE2 byte. So this test uses
the em-dash CHARACTER literal `—` (which IS the raw bytes E2 80 94) and the `â`
character (C3 A2, the double-encode tell), plus a `_raw` helper for lone bytes.
"""

from std.os import makedirs
from security.sandbox import Sandbox, SandboxPolicy, _write, RunHandle


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) != -1


def _raw(byte_vals: List[Int]) raises -> String:
    """Build a String holding the exact raw bytes given (may be invalid UTF-8 —
    used to inject a lone multi-byte lead byte at a poll boundary)."""
    var buf = List[UInt8]()
    for i in range(len(byte_vals)):
        buf.append(UInt8(byte_vals[i]))
    return String(unsafe_from_utf8=Span(buf))


def _mk_sandbox() raises -> Sandbox:
    var pol = SandboxPolicy(String("/tmp"), String("/tmp"))
    return Sandbox(pol^, String("unused.template"))


def main() raises:
    var ok = True
    var base = String("/tmp/pb_emdash_test")
    makedirs(base, exist_ok=True)

    var sb = _mk_sandbox()

    # ── whole line with an em-dash written before the first poll ────────────────
    var out1 = base + "/whole.out"
    # The `—` literal is the raw 3 UTF-8 bytes E2 80 94.
    _write(out1, "restaurant — spending by month\n")
    var h1 = RunHandle(0, out1, 0, String(""))
    var lines1 = sb.run_poll(h1)
    var got1 = String("") if len(lines1) == 0 else lines1[0]
    ok = _expect(
        "whole line: em-dash preserved (raw —)",
        _has(got1, "—"),
        ok,
    )
    # "â" = C3 A2 = the double-encode tell.
    ok = _expect(
        "whole line: NOT double-encoded (no â)",
        not _has(got1, "â"),
        ok,
    )
    ok = _expect(
        "whole line: exact text round-trips",
        got1 == "restaurant — spending by month",
        ok,
    )

    # ── a multi-byte char SPLIT across two polls stitches back whole ────────────
    # First write "AB" + only the em-dash's LEAD byte (E2). The old byte-by-byte
    # decode would have already corrupted that lone byte; the raw-slice path must
    # carry it in `h.pending` and reassemble it whole when the rest arrives.
    var out2 = base + "/split.out"
    _write(out2, _raw([0x41, 0x42, 0xE2]))  # "AB" + em-dash lead byte
    var h2 = RunHandle(0, out2, 0, String(""))
    var poll_a = sb.run_poll(h2)  # no newline yet → no complete line
    ok = _expect("split: no complete line before newline", len(poll_a) == 0, ok)
    # now the rest of the em-dash + tail + a newline arrive
    _write(out2, _raw([0x41, 0x42, 0xE2, 0x80, 0x94, 0x5A, 0x0A]))  # "AB—Z\n"
    var poll_b = sb.run_poll(h2)
    var got2 = String("") if len(poll_b) == 0 else poll_b[0]
    ok = _expect(
        "split: reassembled line has intact em-dash",
        _has(got2, "—"),
        ok,
    )
    ok = _expect(
        "split: reassembled line NOT double-encoded",
        not _has(got2, "â"),
        ok,
    )
    ok = _expect("split: exact text 'AB—Z'", got2 == "AB—Z", ok)

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("emdash-utf8-test failed")
