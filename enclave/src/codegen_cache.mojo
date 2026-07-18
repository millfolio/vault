"""Codegen disk cache — a local persistent cache for the REMOTE (Anthropic) codegen
call in `transport.RemoteClient`.

A poor-man's alternative to Anthropic's server-side prompt caching: when the SAME
frontier request comes in again (same system prompt + aliased manifest + question +
model + max_tokens), return the previously-generated program from disk and skip the
network call entirely — no egress, no token spend.

WHY THIS IS SAFE: the cached value is the codegen *program*, which the orchestrator
re-executes over the LIVE vault on every run — it is NOT the final answer. Identical
request bytes ⇒ identical program. If the vault schema changes, the aliased manifest
embedded in the request changes ⇒ a different key ⇒ a cache miss ⇒ a fresh program.
So a hit is always a valid program for that exact request.

KEY: a STABLE content hash (FNV-1a 64-bit → 16 hex chars) of the FINAL request body
bytes. NOT the builtin `hash()` — that is per-process randomized and useless for a
persistent disk cache. Because the body embeds the model string, the model is
inherently in the key; the entry also records it explicitly for debugging.

Best-effort throughout: a write failure must never break codegen (all writes swallow
errors). Toggle off with `MILLFOLIO_CODEGEN_CACHE=0`.
"""

from std.os import getenv, makedirs, remove
from std.os.path import exists
from json import loads


comptime _HEX = "0123456789abcdef"


def codegen_cache_enabled() -> Bool:
    """Cache is ON by default; `MILLFOLIO_CODEGEN_CACHE=0` disables it."""
    return getenv("MILLFOLIO_CODEGEN_CACHE", "") != "0"


def codegen_cache_dir() -> String:
    """The persistent per-install cache dir, or "" when there's no config dir.

    `MILLFOLIO_CODEGEN_CACHE_DIR` overrides; otherwise
    `<HOME>/.config/enclave/codegen-cache` (parallel to config.json — see
    settings.config_path()). Empty HOME ⇒ "" ⇒ callers skip caching.
    """
    var override = getenv("MILLFOLIO_CODEGEN_CACHE_DIR", "")
    if override != "":
        return override
    var home = getenv("HOME", "")
    if home == "":
        return String("")
    return home + "/.config/enclave/codegen-cache"


def stable_hash_hex(s: String) -> String:
    """FNV-1a 64-bit over the UTF-8 bytes of `s`, as 16 lowercase hex chars.

    Deterministic across processes/machines (unlike the builtin `hash()`), so the
    same request always maps to the same on-disk entry.
    """
    var h: UInt64 = 0xCBF29CE484222325  # FNV offset basis
    var prime: UInt64 = 0x100000001B3  # FNV prime
    var b = s.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(Int(b[i]))) * prime  # wraps mod 2**64
    # 64 bits → 16 hex nibbles, most-significant first.
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((h >> UInt64(shift)) & UInt64(0xF))
        out += String(_HEX[byte=nib])
        shift -= 4
    return out^


def _entry_path(dir: String, key: String) -> String:
    return dir + "/" + key + ".json"


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o^


def codegen_cache_read(dir: String, key: String) -> Optional[String]:
    """Return the cached PROGRAM for `key`, or None on any miss/error.

    Best-effort: a missing file, malformed JSON, or empty program all read as a
    clean miss (None) — never raises.
    """
    try:
        var path = _entry_path(dir, key)
        if not exists(path):
            return None
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var j = loads(text)
        var prog = j["program"].string_value()
        if prog.byte_length() == 0:
            return None
        return Optional[String](prog^)
    except:
        return None


def codegen_cache_write(
    dir: String, key: String, model: String, body_len: Int, program: String
):
    """Persist an entry for `key`: the program + metadata (model, body digest/length).

    Best-effort — swallows every error so a cache-write failure can NEVER break
    codegen. Callers must only invoke this on a genuine success (HTTP 200 + a
    non-empty program); this function does not re-check that.
    """
    if program.byte_length() == 0:
        return  # never cache an empty program
    try:
        makedirs(dir)
    except:
        pass  # already exists / created concurrently
    try:
        var entry = String('{"model":"') + _json_escape(model) + '",'
        entry += '"body_hash":"' + key + '",'
        entry += '"body_len":' + String(body_len) + ","
        entry += '"program":"' + _json_escape(program) + '"}'
        var path = _entry_path(dir, key)
        with open(path, "w") as f:
            f.write(entry)
    except:
        pass  # disk full / permissions / etc. — proceed as if uncached
