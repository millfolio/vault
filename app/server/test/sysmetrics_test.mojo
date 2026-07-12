"""sysmetrics_test — unit tests for the parse/fetch split (sysmetrics.mojo).

Builds + runs as a plain Mojo program: `pixi run test-sysmetrics`.
Covers the pure parse half (`_parse_leading_int`), the fetch half
(`_sample_int` — driven hermetically with `printf`-to-temp-file pipelines, no
`ioreg`/`vm_stat` dependency), and `_dir_size` over a temp tree. The real
samplers (`_gpu_util_pct` etc.) are those two halves plus a macOS-only
pipeline string, so they stay untested by design.
"""

from std.os import makedirs, remove, rmdir

from sysmetrics import _parse_leading_int, _sample_int, _dir_size


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_int(got: Int, want: Int, what: String) raises:
    if got != want:
        raise Error(
            "FAIL: "
            + what
            + "\n  got:  "
            + String(got)
            + "\n  want: "
            + String(want)
        )


def main() raises:
    # ── _parse_leading_int: first digit run, -1 when none ────────────────────────
    expect_int(_parse_leading_int("42"), 42, "plain integer")
    expect_int(_parse_leading_int("0"), 0, "zero parses as 0, not -1")
    expect_int(_parse_leading_int("007"), 7, "leading zeros collapse")
    expect_int(
        _parse_leading_int("37\n"), 37, "trailing newline (the samplers)"
    )
    expect_int(_parse_leading_int("  85 "), 85, "surrounding whitespace")
    expect_int(_parse_leading_int("abc42def7"), 42, "FIRST digit run wins")
    expect_int(_parse_leading_int("12.9"), 12, "stops at the first non-digit")
    expect_int(
        _parse_leading_int("25769803776"),
        25769803776,
        "hw.memsize-sized value (24 GiB in bytes)",
    )
    expect_int(_parse_leading_int(""), -1, "empty → -1")
    expect_int(_parse_leading_int("n/a\n"), -1, "no digits → -1")

    # ── _sample_int: run a pipeline that redirects into the temp file, parse it ──
    var out = String("/tmp/millfolio-sysmetrics-test.out")
    expect_int(
        _sample_int("printf 63 > '" + out + "'", out),
        63,
        "pipeline output read back",
    )
    expect_int(
        _sample_int("printf 'no digits' > '" + out + "'", out),
        -1,
        "non-numeric pipeline output → -1",
    )
    expect_int(
        _sample_int("rm -f '" + out + "'", out),
        -1,
        "missing output file → -1",
    )

    # ── _dir_size: recursive byte size over a temp tree ──────────────────────────
    var root = String("/tmp/millfolio-sysmetrics-test-dir")
    makedirs(root + "/sub", exist_ok=True)
    with open(root + "/a.txt", "w") as f:
        f.write(String("12345"))  # 5 bytes
    with open(root + "/sub/b.txt", "w") as f:
        f.write(String("1234567890"))  # 10 bytes
    expect_int(_dir_size(root), 15, "recursive dir size sums the tree")
    expect_int(_dir_size(root + "/a.txt"), 5, "single file size")
    expect_int(_dir_size(root + "/nope"), 0, "missing path → 0")
    remove(root + "/a.txt")
    remove(root + "/sub/b.txt")
    rmdir(root + "/sub")
    rmdir(root)

    print("sysmetrics_test: all tests passed")
