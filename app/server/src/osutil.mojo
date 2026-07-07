"""osutil — foundational path / env / libc / small-utility helpers.

The BASE module of the app server: it depends only on the standard library, so
every other extracted module (sysmetrics, auth, …) and server.mojo can import
from it with no risk of an import cycle. It holds the process-wide knobs
(`_port`, `_workers`), the on-device data/web dir resolution (`_config_dir`,
`_web_root`), the libc bridges (`_cstr`, `_chmod`, `_epoch_s`), the demo probe
(`_is_demo`), and the tiny generic string/int utilities used across the server
(`_atoi`, `_lower_ascii`, `_tsv_unescape`, `_kind_for_name`, `_sort_names`).

Pure moves out of server.mojo — behaviour is identical.
"""

from std.memory import alloc, UnsafePointer
from std.os import getenv
from std.ffi import external_call, c_char, c_int

comptime DEFAULT_PORT = 10000


def _port() raises -> Int:
    """The HTTP/WS listen port — MILLFOLIO_PORT (digits) overrides, else 10000. Lets a
    second instance (e.g. the demo) coexist on the same box without a rebuild.
    """
    var s = String(getenv("MILLFOLIO_PORT", "").strip())
    if s == "":
        return DEFAULT_PORT
    var n = 0
    var any = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        else:
            break
    return n if (any and n > 0 and n <= 65535) else DEFAULT_PORT


def _workers() raises -> Int:
    """Worker thread count — MILLFOLIO_WORKERS (digits) overrides, else 1. The default
    keeps the real product single-threaded (one local user); the demo sets it >1 so
    concurrent visitors don't block each other at codegen/approval. The actual sandboxed
    run stays serial regardless — see the run-queue (flock) in `on_connect`."""
    var s = String(getenv("MILLFOLIO_WORKERS", "").strip())
    if s == "":
        return 1
    var n = 0
    var any = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        else:
            break
    return n if (any and n > 0 and n <= 256) else 1


def _web_root() -> String:
    """The dir holding the built UI. $MILLFOLIO_WEB_DIR (an ABSOLUTE path set by the
    launcher) so serving never depends on the process's cwd; falls back to the
    cwd-relative web/dist for `pixi run`/dev."""
    return getenv("MILLFOLIO_WEB_DIR", "web/dist")


def _config_dir() -> String:
    """The on-device DATA dir — MUST match vault/core `store.config_dir()`: the
    macOS-native `~/Library/Application Support/Millfolio/data`, overridable via
    `MILLFOLIO_DATA_DIR`. Feeds the vault view + the System page paths + stats/asks.
    """
    var d = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    if d != "":
        return d
    return getenv("HOME", ".") + "/Library/Application Support/Millfolio/data"


def _cstr(s: String) -> UnsafePointer[c_char, MutUntrackedOrigin]:
    """NUL-terminated C string for `external_call` (caller `.free()`s it)."""
    var n = s.byte_length()
    var p = alloc[c_char](n + 1)
    var sp = s.unsafe_ptr()
    for i in range(n):
        (p + i).init_pointee_copy(c_char(Int(sp[i])))
    (p + n).init_pointee_copy(c_char(0))
    return p


def _chmod(path: String, mode: Int):
    """Best-effort `chmod(path, mode)` via libc. Mojo's `open(...)` and
    `makedirs` create with the process umask (typically 0644/0755); the data dir
    and JSONL stores hold personal financial data (questions, answers, extracted
    transactions), so we tighten them to owner-only after creation."""
    var cp = _cstr(path)
    _ = external_call["chmod", c_int](cp, c_int(mode))
    cp.free()


def _is_demo() raises -> Bool:
    """The public replay demo (port 10010, or MILLFOLIO_DEMO set). Its transactions
    are SYNTHETIC + public-safe, and visitors have no Touch ID, so the amount gate is
    bypassed there (amounts always shown). Never true for the real product (:10000).
    """
    if String(getenv("MILLFOLIO_DEMO", "").strip()) != "":
        return True
    return _port() == 10010


def _epoch_s() -> Int64:
    """Unix epoch seconds, right now — time(2) with a NULL arg. For stats timestamps
    (perf_counter_ns is monotonic, not wall-clock, so it can't date a record).
    """
    var null = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(0)
    )
    return external_call["time", Int64](null)


def _atoi(s: String) -> Int:
    """Parse a non-negative integer (digits only)."""
    var n = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
    return n


def _tsv_unescape(s: String) raises -> String:
    """Inverse of vault/core's TSV escaping (manifest stores escaped name/dir).
    """
    var out = String("")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 92 and i + 1 < len(bytes):  # backslash
            var n = Int(bytes[i + 1])
            if n == 116:
                out += "\t"
                i += 2
                continue
            elif n == 110:
                out += "\n"
                i += 2
                continue
            elif n == 114:
                out += "\r"
                i += 2
                continue
            elif n == 92:
                out += "\\"
                i += 2
                continue
        out += chr(c)
        i += 1
    return out^


def _lower_ascii(s: String) -> String:
    """ASCII-lowercase (enough for file extensions)."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:  # 'A'..'Z'
            c += 32
        out += chr(c)
    return out^


def _kind_for_name(name: String) -> String:
    """Vault kind from a filename's extension (csv/pdf/md), else "" to skip.
    Mirrors vault/core manifest so aliases line up with the index."""
    if name.find(".") == -1:
        return String("")
    var parts = name.split(".")
    var ext = _lower_ascii(String(parts[len(parts) - 1]))
    if ext == "csv":
        return String("csv")
    if ext == "pdf":
        return String("pdf")
    if ext == "md" or ext == "markdown":
        return String("md")
    if ext == "docx":
        return String("docx")
    return String("")


def _sort_names(mut names: List[String]):
    """In-place insertion sort so aliases are stable across runs (as manifest).
    """
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j - 1] > names[j]:
            var tmp = names[j - 1].copy()
            names[j - 1] = names[j].copy()
            names[j] = tmp^
            j -= 1
