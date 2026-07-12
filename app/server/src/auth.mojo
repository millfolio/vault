"""auth — secrets, tokens, and the in-app API-key store (file I/O).

The credential/gate plumbing for the app server, grouped by concern:

  * amount-reveal tokens — the local-capability secret (`.reveal-secret`) + the
    15-min bearer token minted by the passphrase and native local-unlock paths;
  * the in-app Anthropic API-key store — the 0600 `.anthropic-key` file I/O
    (kept OUT of the pure, unit-tested `apikey.mojo`, whose docstring explicitly
    says the file I/O lives elsewhere because it needs `_config_dir` + libc chmod);
  * Cloudflare Turnstile — the demo-only human/bot gate (siteverify);
  * demo-access tokens — the short-lived tokens minted after a Turnstile solve.

Depends on `osutil` (`_config_dir`, `_chmod`, `_cstr`, `_epoch_s`, `_is_demo`),
`settings.Config`, `logging.log`, `events.json_escape`, and flare — none of which
import back here, so there is no cycle. Pure moves out of server.mojo — behaviour
is identical.
"""

from std.os import getenv, remove
from std.os.path import exists
from std.ffi import external_call, c_int

from flare.prelude import *
from flare.http import HttpClient

from settings import Config
from logging import log
from events import json_escape

from osutil import _config_dir, _chmod, _cstr, _epoch_s, _is_demo


# ── amount-reveal tokens ───────────────────────────────────────────────────────


def _reveal_token_path() -> String:
    return _config_dir() + "/reveal_token.txt"


def _reveal_secret_path() -> String:
    """The LOCAL-CAPABILITY secret: a random token in the data dir (0600) that
    proves the caller is a local app on this machine. The native menu-bar app
    reads it (after a Touch-ID / login-password check) and POSTs it to
    `/api/amounts/unlock-local` to mint a reveal token — the SAME token the
    passphrase path mints. Not a hard boundary (any local process that can read
    the data dir could read it, just like `mill get amount-password` exposes the
    phrase); it matches the gate's privacy-screen threat model."""
    return _config_dir() + "/.reveal-secret"


def _ensure_reveal_secret() -> String:
    """Create the local-capability secret on first run (0600 owner-only) if
    absent; return its current value. Best-effort — a read/write failure returns
    "" so the local-unlock endpoint simply stays closed (falls back to the
    passphrase). Called at startup AND lazily from the endpoint."""
    var p = _reveal_secret_path()
    try:
        if exists(p):
            var cur: String
            with open(p, "r") as f:
                cur = String(f.read().strip())
            if cur != "":
                return cur^
        var secret = _new_token() + _new_token()  # 256-bit
        with open(p, "w") as f:
            f.write(secret)
        _chmod(p, 0o600)  # owner read/write only
        return secret^
    except:
        return String("")


def _mint_reveal_token() raises -> String:
    """Mint the amount-reveal bearer token: a fresh 128-bit token written to the
    reveal-token file with a 15-min TTL, returned to the caller. SHARED by the
    passphrase path (`/api/auth/unlock`) and the native local-unlock path
    (`/api/amounts/unlock-local`) so both mint an identical token — nothing
    downstream (`_reveal_authorized`) changes."""
    var tok = _new_token()
    with open(_reveal_token_path(), "w") as f:
        f.write(tok + " " + String(_epoch_s() + 900))  # 15-min TTL
    return tok^


def _const_time_eq(a: String, b: String) -> Bool:
    """Length-then-XOR compare that avoids an early-out on the first differing
    byte (timing side-channel). Not constant across differing LENGTHS, which is
    acceptable here — the secret is fixed-length."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var na = len(ab)
    var nb = len(bb)
    var diff = 1 if na != nb else 0
    var n = na if na < nb else nb
    for i in range(n):
        diff |= Int(ab[i]) ^ Int(bb[i])
    return diff == 0


def _hex_nibble(n: Int) -> String:
    return chr(48 + n) if n < 10 else chr(87 + n)  # 0-9 then a-f


def _new_token() -> String:
    """A 128-bit random reveal token (32 hex chars) via libc arc4random — minted
    when the amount passphrase is entered correctly, then required (Bearer) on
    `?amounts=1`."""
    var out = String("")
    for _ in range(4):
        var v = Int(external_call["arc4random", UInt32]())
        for i in range(8):
            out += _hex_nibble((v >> ((7 - i) * 4)) & 0xF)
    return out^


# ── in-app Anthropic API-key store (0600 file I/O) ─────────────────────────────


def _apikey_path() -> String:
    """The in-app Anthropic API-key store: a 0600 file in the data dir. Written
    when a user pastes a key into the in-app Settings field (native `.app` users
    who never set `ANTHROPIC_API_KEY`); read by codegen (`_apply_persisted_apikey`)
    when the process env has no key. Mirrors the `.reveal-secret` owner-only
    scheme — the file holds a secret, so it's never world-readable or logged."""
    return _config_dir() + "/.anthropic-key"


def _read_apikey_file() -> String:
    """The persisted key (trimmed), or "" when absent/unreadable. Best-effort —
    any failure means "no stored key" so codegen falls back to local-only mode.
    """
    try:
        var p = _apikey_path()
        if exists(p):
            with open(p, "r") as f:
                return String(f.read().strip())
    except:
        pass
    return String("")


def _write_apikey_file(key: String) raises:
    """Persist `key` atomically at 0600: write a temp file, tighten it to
    owner-only, then rename over the target so a reader never sees a partial or
    a briefly world-readable file. The key is a SECRET — never logged."""
    var trimmed = String(key.strip())
    var final = _apikey_path()
    var tmp = final + ".tmp"
    with open(tmp, "w") as f:
        f.write(trimmed)
    _chmod(tmp, 0o600)  # owner read/write only, BEFORE it's visible at `final`
    var s = _cstr(tmp)
    var d = _cstr(final)
    var rc = external_call["rename", c_int](s, d)
    s.free()
    d.free()
    if Int(rc) != 0:
        raise Error("could not persist API key")


def _clear_apikey_file():
    """Remove the persisted key (best-effort). Codegen then reverts to the
    process env / local-only mode on the next question."""
    try:
        var p = _apikey_path()
        if exists(p):
            remove(p)
    except:
        pass


def _apply_persisted_apikey(mut cfg: Config):
    """Inject the in-app key into the freshly-loaded config when the environment
    supplied none. `load_config()` already honours `ANTHROPIC_API_KEY` from the
    process env (the launch-agent forward) with highest precedence; only when
    that's empty do we fall back to the persisted `.anthropic-key` file. When we
    do supply a key, restore the remote token budget (load_config zeroes it under
    a keyless config → local-only mode) so codegen actually reaches the frontier
    model. Called right after every `load_config()` on the ask/codegen path, so a
    key pasted in-app takes effect on the very next question — no restart."""
    if cfg.api_key != "":
        return  # env (or config file) already provided one — leave it be
    var stored = _read_apikey_file()
    if stored == "":
        return  # nothing persisted — stay in local-only mode
    cfg.api_key = stored^
    cfg.remote_token_budget = -1  # re-enable remote (load_config forced 0)


# ── Cloudflare Turnstile: demo-only human/bot gate ─────────────────────────────
# The public replay demo (demo.millfolio.app) gates chat behind a Turnstile check:
# the intro modal solves it, POSTs the token to /api/demo/verify, we validate it with
# Cloudflare siteverify, then mint a short-lived demo-access token the client echoes
# on each WS chat frame (on_connect rejects a missing/invalid one). Enabled ONLY when
# MILLFOLIO_TURNSTILE_SECRET is set AND we're the demo — so the real product + local
# dev are untouched. Keys come from a Cloudflare Turnstile widget (sitekey is public,
# secret is server-side); Cloudflare's test keys work on any host incl. localhost.


def _turnstile_sitekey() -> String:
    return String(getenv("MILLFOLIO_TURNSTILE_SITEKEY", "").strip())


def _turnstile_secret() -> String:
    return String(getenv("MILLFOLIO_TURNSTILE_SECRET", "").strip())


def _turnstile_enabled() raises -> Bool:
    """Active only in the demo AND when a secret is configured (else a no-op).
    """
    return _is_demo() and _turnstile_secret() != ""


def _demo_tokens_path() -> String:
    return _config_dir() + "/demo_tokens.tsv"


def _verify_turnstile(token: String) raises -> Bool:
    """POST the client token to Cloudflare siteverify with our secret; True iff
    `success`. Fails CLOSED — any empty token / network / parse error → False. Uses a
    JSON body so the token's base64url chars need no form-encoding.

    We do NOT send `remoteip`: behind the cloudflared tunnel the origin's view of the
    client IP can differ from where the token was issued, and a mismatch there is a
    needless failure mode (the param is optional). On failure we log the error-codes +
    token length so a rejection is diagnosable in the server log."""
    if token == "":
        log("turnstile: empty token")
        return False
    var body = String('{"secret":') + json_escape(_turnstile_secret())
    body += ',"response":' + json_escape(token) + "}"
    var req = Request(
        method="POST",
        url="https://challenges.cloudflare.com/turnstile/v0/siteverify",
        body=List[UInt8](body.as_bytes()),
    )
    req.headers.set("content-type", "application/json")
    try:
        var client = HttpClient()
        var resp = client.send(req)
        var v = resp.json()
        var ok = v["success"].bool_value()
        if not ok:
            var codes = String("")
            try:
                var arr = v["error-codes"]
                for i in range(arr.array_count()):
                    codes += String(arr[i].string_value()) + " "
            except:
                pass
            log(
                "turnstile siteverify rejected: codes=["
                + codes
                + "] token_len="
                + String(token.byte_length())
            )
        return ok
    except e:
        log("turnstile siteverify error: " + String(e))
        return False


# ── demo-access tokens (minted after a Turnstile solve) ────────────────────────


def _mint_demo_token() raises -> String:
    """Append a fresh 30-min demo-access token to the set (concurrent visitors each
    get their own), pruning expired entries as we rewrite. Returns the new token.
    """
    var tok = _new_token()
    var exp = _epoch_s() + Int64(1800)
    var kept = String("")
    if exists(_demo_tokens_path()):
        var cur: String
        with open(_demo_tokens_path(), "r") as f:
            cur = f.read()
        var lines = cur.split("\n")
        for i in range(len(lines)):
            var ln = String(lines[i].strip())
            if ln == "":
                continue
            var parts = ln.split("\t")
            if len(parts) >= 2 and _epoch_s() < Int64(
                atol(String(parts[1].strip()))
            ):
                kept += ln + "\n"
    kept += tok + "\t" + String(exp) + "\n"
    with open(_demo_tokens_path(), "w") as f:
        f.write(kept)
    return tok^


def _demo_token_valid(tok: String) raises -> Bool:
    """True iff `tok` is a known, unexpired demo-access token (minted after a
    successful Turnstile solve)."""
    if tok == "" or not exists(_demo_tokens_path()):
        return False
    var cur: String
    with open(_demo_tokens_path(), "r") as f:
        cur = f.read()
    var lines = cur.split("\n")
    for i in range(len(lines)):
        var parts = String(lines[i].strip()).split("\t")
        if len(parts) >= 2 and String(parts[0].strip()) == tok:
            return _epoch_s() < Int64(atol(String(parts[1].strip())))
    return False
