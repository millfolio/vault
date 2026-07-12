"""osutil_test — unit tests for the foundational path/env/string helpers (osutil.mojo).

Builds + runs as a plain Mojo program (stdlib only): `pixi run test-osutil`.
Covers the pure string/int utilities (`_atoi`, `_tsv_unescape`, `_lower_ascii`,
`_kind_for_name`, `_sort_names`) and the env-driven knobs (`_port`, `_workers`,
`_config_dir`, `_is_demo`) — for the env ones we drive both the parsed override
(via `setenv`) and the unset default. Skips the thin libc syscall wrappers
(`_cstr`/`_chmod`/`_epoch_s`).
"""

from std.os import setenv

from osutil import (
    _atoi,
    _tsv_unescape,
    _lower_ascii,
    _kind_for_name,
    _sort_names,
    _port,
    _workers,
    _config_dir,
    _is_demo,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


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
    # ── _atoi: leading/embedded digits only, no sign handling ────────────────────
    expect_int(_atoi("123"), 123, "plain integer")
    expect_int(_atoi(""), 0, "empty → 0")
    expect_int(_atoi("abc"), 0, "non-numeric → 0")
    expect_int(_atoi("12ab"), 12, "trailing junk ignored")
    # No sign handling: '-' is a non-digit, silently skipped → digits parsed.
    expect_int(_atoi("-5"), 5, "leading minus ignored (unsigned parse)")

    # ── _tsv_unescape: inverse of vault/core TSV escaping ────────────────────────
    expect_eq(_tsv_unescape("\\t"), "\t", "backslash-t → tab")
    expect_eq(_tsv_unescape("\\n"), "\n", "backslash-n → newline")
    expect_eq(_tsv_unescape("\\\\"), "\\", "double backslash → single")
    expect_eq(_tsv_unescape("plain"), "plain", "no escapes → identity")
    expect_eq(
        _tsv_unescape("a\\tb\\nc"), "a\tb\nc", "mixed escapes in a string"
    )

    # ── _lower_ascii ─────────────────────────────────────────────────────────────
    expect_eq(_lower_ascii("ABC"), "abc", "all upper → lower")
    expect_eq(_lower_ascii("aB3.Z"), "ab3.z", "mixed, digits/punct untouched")
    expect_eq(_lower_ascii(""), "", "empty → empty")

    # ── _kind_for_name: extension → vault kind ───────────────────────────────────
    expect_eq(_kind_for_name("statement.csv"), "csv", "csv")
    expect_eq(_kind_for_name("STMT.PDF"), "pdf", "uppercase ext lowered → pdf")
    expect_eq(_kind_for_name("notes.md"), "md", "md")
    expect_eq(_kind_for_name("notes.markdown"), "md", "markdown → md")
    expect_eq(_kind_for_name("resume.docx"), "docx", "docx")
    expect_eq(_kind_for_name("data.txt"), "", "unknown ext → skip")
    expect_eq(_kind_for_name("noext"), "", "no extension → skip")

    # ── _sort_names: ascending, in place, duplicates preserved ───────────────────
    var names = ["cherry", "apple", "banana"]
    _sort_names(names)
    expect_eq(names[0], "apple", "sorted[0]")
    expect_eq(names[1], "banana", "sorted[1]")
    expect_eq(names[2], "cherry", "sorted[2]")

    var already = ["a", "b", "c"]
    _sort_names(already)
    expect(
        already[0] == "a" and already[1] == "b" and already[2] == "c",
        "already-sorted stays sorted",
    )

    # Stable: equal keys keep their relative order & count (insertion sort).
    var dups = ["b", "a", "a", "c"]
    _sort_names(dups)
    expect(
        dups[0] == "a" and dups[1] == "a" and dups[2] == "b" and dups[3] == "c",
        "duplicates kept, sorted",
    )

    # ── _port: MILLFOLIO_PORT override, else default 10000 ───────────────────────
    _ = setenv("MILLFOLIO_PORT", "8080", True)
    expect_int(_port(), 8080, "valid port override")
    _ = setenv("MILLFOLIO_PORT", "", True)
    expect_int(_port(), 10000, "empty → default 10000")
    _ = setenv("MILLFOLIO_PORT", "abc", True)
    expect_int(_port(), 10000, "non-numeric → default")
    _ = setenv("MILLFOLIO_PORT", "0", True)
    expect_int(_port(), 10000, "0 out of range → default")
    _ = setenv("MILLFOLIO_PORT", "99999", True)
    expect_int(_port(), 10000, ">65535 → default")
    _ = setenv("MILLFOLIO_PORT", "", True)  # reset for later _is_demo tests

    # ── _workers: MILLFOLIO_WORKERS override, else default 1 ─────────────────────
    _ = setenv("MILLFOLIO_WORKERS", "4", True)
    expect_int(_workers(), 4, "valid worker override")
    _ = setenv("MILLFOLIO_WORKERS", "", True)
    expect_int(_workers(), 1, "empty → default 1")
    _ = setenv("MILLFOLIO_WORKERS", "0", True)
    expect_int(_workers(), 1, "0 out of range → default")
    _ = setenv("MILLFOLIO_WORKERS", "999", True)
    expect_int(_workers(), 1, ">256 → default")
    _ = setenv("MILLFOLIO_WORKERS", "", True)

    # ── _config_dir: MILLFOLIO_DATA_DIR override, else HOME-derived default ───────
    _ = setenv("MILLFOLIO_DATA_DIR", "/tmp/millfolio-osutil-test", True)
    expect_eq(
        _config_dir(),
        "/tmp/millfolio-osutil-test",
        "explicit data-dir override",
    )
    _ = setenv("MILLFOLIO_DATA_DIR", "", True)
    _ = setenv("HOME", "/Users/someone", True)
    expect_eq(
        _config_dir(),
        "/Users/someone/Library/Application Support/Millfolio/data",
        "unset → HOME-derived default",
    )

    # ── _is_demo: MILLFOLIO_DEMO set OR port 10010 ───────────────────────────────
    _ = setenv("MILLFOLIO_DEMO", "", True)
    _ = setenv("MILLFOLIO_PORT", "", True)
    expect(not _is_demo(), "not demo by default (port 10000)")
    _ = setenv("MILLFOLIO_DEMO", "1", True)
    expect(_is_demo(), "MILLFOLIO_DEMO set → demo")
    _ = setenv("MILLFOLIO_DEMO", "", True)
    _ = setenv("MILLFOLIO_PORT", "10010", True)
    expect(_is_demo(), "port 10010 → demo")
    _ = setenv("MILLFOLIO_PORT", "", True)

    print("osutil_test: OK")
