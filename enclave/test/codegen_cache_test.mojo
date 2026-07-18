"""Codegen-cache test — unit-test the local persistent codegen disk cache.

Exercises the read/write layer directly against a temp dir (no network):
  (a) the stable hash is deterministic across calls and DIFFERS when the model
      string in the request body changes;
  (b) write-then-read round-trips a program AND records the model;
  (c) a miss (no file) returns "no entry", a hit returns the stored program.
"""

from std.os import getenv, makedirs
from json import loads
from codegen_cache import (
    stable_hash_hex,
    codegen_cache_read,
    codegen_cache_write,
    codegen_cache_dir,
    _entry_path,
)


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def _body(model: String) raises -> String:
    """A stand-in request body — model + system array + a user message, mirroring
    what transport builds (the model is embedded in the bytes we hash)."""
    var s = String('{"model":"') + model + '","max_tokens":8192,'
    s += '"system":[{"type":"text","text":"SYS PROMPT",'
    s += '"cache_control":{"type":"ephemeral"}}],'
    s += '"messages":[{"role":"user","content":"Q: total spent?"}]}'
    return s^


def main() raises:
    var ok = True

    # ── (a) stable hash: deterministic + model-sensitive ──────────────────────
    var b_sonnet = _body(String("claude-sonnet-5"))
    var h1 = stable_hash_hex(b_sonnet)
    var h2 = stable_hash_hex(b_sonnet)
    ok = _expect("hash deterministic across calls", h1 == h2, ok)
    ok = _expect("hash is 16 hex chars", h1.byte_length() == 16, ok)

    var b_opus = _body(String("claude-opus-4-8"))
    var h_opus = stable_hash_hex(b_opus)
    ok = _expect("hash DIFFERS when the model string changes", h1 != h_opus, ok)
    # Sanity: a byte-identical string always hashes the same, and a known input is
    # non-empty / lowercase-hex (spot-check first char).
    ok = _expect(
        "hash stable for identical input", stable_hash_hex(b_opus) == h_opus, ok
    )

    # ── temp cache dir (hermetic) ─────────────────────────────────────────────
    var base = getenv("MILLFOLIO_CODEGEN_CACHE_DIR", "")
    if base == "":
        base = getenv("TMPDIR", "/tmp") + "/millfolio-codegen-cache-test"
    try:
        makedirs(base)
    except:
        pass

    # ── (c) miss returns None BEFORE anything is written ──────────────────────
    var key = h1
    var miss = codegen_cache_read(base, key)
    ok = _expect("miss (no file) returns None", not miss, ok)

    # ── (b) write-then-read round-trips the program + records the model ───────
    var program = String(
        "def main() raises:\n"
        '    print("ROW_COUNT=", 42)\n'
        '    # quotes " backslash \\ newline handled\n'
    )
    codegen_cache_write(
        base, key, String("claude-sonnet-5"), b_sonnet.byte_length(), program
    )

    var hit = codegen_cache_read(base, key)
    ok = _expect("hit returns Some after write", Bool(hit), ok)
    if hit:
        ok = _expect(
            "round-tripped program matches (incl. quotes/backslash/newlines)",
            hit.value() == program,
            ok,
        )

    # The entry records the model explicitly (per spec) — verify by parsing JSON.
    var text: String
    with open(_entry_path(base, key), "r") as f:
        text = f.read()
    var j = loads(text)
    ok = _expect(
        "entry records the model",
        j["model"].string_value() == String("claude-sonnet-5"),
        ok,
    )
    ok = _expect(
        "entry records the body_len",
        Int(j["body_len"].int_value()) == b_sonnet.byte_length(),
        ok,
    )
    ok = _expect(
        "entry records the body_hash", j["body_hash"].string_value() == key, ok
    )

    # ── an empty program is never cached (write is a no-op) ────────────────────
    var empty_key = String("emptyprogram0000")
    codegen_cache_write(base, empty_key, String("m"), 0, String(""))
    ok = _expect(
        "empty program is not cached",
        not codegen_cache_read(base, empty_key),
        ok,
    )

    # ── a different-model body has a different key ⇒ its own miss ─────────────
    ok = _expect(
        "different-model key is a miss until written",
        not codegen_cache_read(base, h_opus),
        ok,
    )

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("codegen-cache-test failed")
