"""apikey — pure helpers for the in-app Anthropic API-key store.

Native `.app` users never set `ANTHROPIC_API_KEY`, so a vault question errors
with "set ANTHROPIC_API_KEY and retry" and there's nowhere to fix it. The app
server offers an in-app field that persists the key to a 0600 file in the data
dir; codegen reads the key from the process env first (launch-agent forward),
else from that file (see server.mojo `_apply_persisted_apikey`), so a pasted key
takes effect on the next question with no restart.

This module holds only the PURE, dependency-light logic (validation + masking +
status JSON) so it can be unit-tested standalone (test/apikey_test.mojo). The
0600 file I/O lives in server.mojo (it needs `_config_dir` + libc `chmod`).

The key is a SECRET: it is stored 0600, never logged, and NEVER echoed back in
full — the API only ever exposes a masked "…last4" hint.
"""


def apikey_looks_valid(key: String) -> Bool:
    """A minimal sanity gate before we persist: non-blank, long enough to be a
    real key, and no embedded whitespace (a paste artifact / truncation). We do
    NOT hard-require the `sk-ant-` prefix — Anthropic could change it and proxy
    setups use other schemes — we only reject obvious blanks/typos."""
    var k = String(key.strip())
    if k.byte_length() < 12:
        return False
    for cp in k.codepoints():
        var c = Int(cp)
        if c == 32 or c == 9 or c == 10 or c == 13:  # space/tab/CR/LF
            return False
    return True


def apikey_hint(key: String) -> String:
    """A masked hint that is safe to return to the client: an ellipsis + the
    LAST 4 characters only, e.g. `…AB12`. Empty for an empty key. This is the
    ONLY view of the stored key the API ever exposes — never the full value."""
    var k = String(key.strip())
    var slices = List[String]()
    for cp in k.codepoint_slices():
        slices.append(String(cp))
    var n = len(slices)
    if n == 0:
        return String("")
    var start = 0
    if n > 4:
        start = n - 4
    var out = String("…")
    for i in range(start, n):
        out += slices[i]
    return out^


def apikey_status_json(is_set: Bool, hint: String) -> String:
    """`{"set": <bool>, "hint": "<…last4>"}` — the shape returned by
    GET/POST/DELETE /api/settings/apikey. `hint` is masked (apikey_hint) and
    contains only key chars + the ellipsis, so no JSON escaping is needed."""
    var set_s = String("true") if is_set else String("false")
    return '{"set":' + set_s + ',"hint":"' + hint + '"}'
