"""Server — the millfolio app backend over HTTP (flare).

Migrated from headgate/src/server.mojo. The vault brains stay in headgate; this
server imports them as a library via `-I ../../headgate/src` (build wired in
pixi.toml + ../../.github/workflows/server.yml). Runs the SAME vault orchestrator
the CLI does, on localhost:10000, behind:

    POST /chat        { "message": <question> }  ->  { "reply": <answer> }
    POST /api/search  { "query": ..., "k": N }   ->  { "hits": [...] }
    GET  /api/vault   ->  { vaultDir, indexed, stats, files[] }  (the vault view)
    GET  /health
    WS   (Upgrade)    ->  streaming chat (status/approval/debug/message events)
    OPTIONS *         (CORS preflight, so a web app on another port can call us)

Single-threaded reactor — one task in flight at a time. The orchestrator lives
in a heap `MillfolioState` reached through a pointer so the borrowed-self handler
can still run `mut` codegen.

VAULT-ONLY: `/chat` always runs the private-vault codegen loop (`run_vault_task`)
over the resolved vault dir.

ONE PORT: the unary HTTP `Api` handler AND the streaming WebSocket chat (`on_connect`)
share a single :10000 listener — flare's `HttpServer.serve(handler, ws_handler)`
upgrades requests carrying the WebSocket headers and routes everything else to the
HTTP handler. (Previously the WS stream needed a second port; flare couldn't
multiplex them.)

    pixi run build   # -> build/millfolio-server, listens on 127.0.0.1:10000
"""

from std.memory import alloc, UnsafePointer
from std.os import getenv, listdir, makedirs, remove
from std.os.path import isfile, isdir, getsize, exists


from flare.prelude import *
from flare.http import Handler, HttpClient
from flare.ws import WsConnection, WsOpcode, WsCloseCode
from flare.runtime._thread import ThreadHandle, _OpaquePtr, _null_ptr

from std.ffi import external_call, c_char, c_int
from std.time import perf_counter_ns

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import (
    Orchestrator,
    PROGRESS_SENTINEL,
    STAT_SENTINEL,
    LOCAL_SENTINEL,
    LOCAL_SEP,
    RESULT_SENTINEL,
)
from transport import DeltaSink
from runqueue import runq_take, runq_peek, runq_done, runq_reset

# The LanceDB-free registry/tags/retag store — the SAME functions the `millfolio`
# CLI uses, so the Tags panel + category editor run in-process (no engine spawn).
from vault.derive.tags import (
    read_categories,
    effective_tags,
    effective_tag_descriptions,
)
from vault.derive.store import (
    tags_report_json,
    transactions_json,
    save_categories,
    preview_categories,
    backfill_status_json,
    backfill_dedup_json,
    ml_backfill_slice,
    set_pause,
    get_priority,
    set_priority,
    nap_ms_for_priority,
    preview_ml_json,
    add_category,
    verify_amount_password,
)
from vaultcfg import vault_dir as resolve_vault_dir
from sandbox import _spawn_capture
from logging import log
from events import (
    field,
    status,
    tags_event,
    tag_proposal_event,
    debug_event,
    approval,
    message,
    error_event,
    json_escape,
)
from store import (
    ask_record_line,
    history_records_array,
    delete_ask_records,
    system_json,
)
from json import loads

comptime DEFAULT_PORT = 10000
comptime EMBED_DIM = 1024  # Qwen3-Embedding-0.6B — mirrors vault/core embed.mojo
# Weight provisioning (downloads moved OUT of the installer, INTO this server).
comptime DEFAULT_CHAT_MODEL = "Qwen/Qwen2.5-3B-Instruct"
comptime EMBED_MODEL = "Qwen/Qwen3-Embedding-0.6B"


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


struct MillfolioState(Movable):
    """The vault orchestrator + vault dir, loaded once and reached by the
    (borrowed-self) handler through a pointer so `run_vault_task` can still take
    `mut self`. `/chat` always runs `run_vault_task` over `vault_dir`."""

    var orch: Orchestrator
    var vault_dir: String

    def __init__(out self, var orch: Orchestrator, var vault_dir: String):
        self.orch = orch^
        self.vault_dir = vault_dir^


def _json_escape(s: String) -> String:
    """Quote + escape `s` as a JSON string (control chars dropped to spaces)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out


def _extract_message(body: String) -> String:
    """Pull `message` out of a `{ "message": ... }` body (empty on any failure).
    """
    try:
        var j = loads(body)
        return j["message"].string_value()
    except:
        return String("")


def _web_root() -> String:
    """The dir holding the built UI. $MILLFOLIO_WEB_DIR (an ABSOLUTE path set by the
    launcher) so serving never depends on the process's cwd; falls back to the
    cwd-relative web/dist for `pixi run`/dev."""
    return getenv("MILLFOLIO_WEB_DIR", "web/dist")


# ── vault view (GET /api/vault) ───────────────────────────────────────────────
# Self-contained, read-only: walk the vault dir + read the index side-table
# (chunks.tsv) and the LanceDB dir on disk — no LanceDB linkage in this binary.
# The file aliasing here mirrors vault/core/src/manifest.mojo EXACTLY (sorted
# names, csv/pdf/md only, alias = "file_<i>") so per-file chunk counts line up
# with the aliases the indexer wrote into chunks.tsv.


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


def _gpu_util_pct() -> Int:
    """Instantaneous GPU utilization (%), read WITHOUT root from IOKit's
    IOAccelerator `PerformanceStatistics` via `ioreg`. A shell pipeline extracts
    the single "Device Utilization %" integer to a temp file we then read.
    Returns -1 when unavailable (non-Apple-GPU host / parse miss) so the bar can
    hide the indicator. The 30-second rolling average is kept CLIENT-side (the
    bottom bar polls this), so a sample stays cheap + stateless."""
    var out_path = _config_dir() + "/.gpu_util"
    # `cd /` first: if a deploy wiped the process's working dir (the bundle tree is
    # re-unpacked on `mill install`), the spawned shell would otherwise spam
    # "shell-init: getcwd: cannot access parent directories" on every poll.
    var cmd = (
        String(
            "cd / 2>/dev/null; ioreg -r -d 1 -c IOAccelerator 2>/dev/null | "
        )
        + "sed -n 's/.*\"Device Utilization %\"=\\([0-9][0-9]*\\).*/\\1/p' | "
        + "head -1 > '"
        + out_path
        + "' 2>/dev/null"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        var cur = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                cur = cur * 10 + (c - 48)
                indig = True
            elif indig:
                break
        return cur if indig else -1
    except:
        return -1


def _memory_gb() -> Int:
    """Total physical RAM in whole GB, read via `sysctl -n hw.memsize` (bytes) —
    same subprocess-to-temp-file pattern as `_gpu_util_pct`. Used by the model
    catalog UI to gray out checkpoints too big to fit in memory. Returns -1 when
    unavailable (non-macOS / parse miss) so the client falls back to enabling all
    models. RAM is fixed for a machine, but /api/models is polled rarely (only when
    the catalog popover opens), so a per-call sample is cheap enough — no caching."""
    var out_path = _config_dir() + "/.mem_bytes"
    # `cd /` first (see `_gpu_util_pct`): a re-unpacked bundle can leave the spawned
    # shell with no valid cwd, which otherwise spams a getcwd warning.
    var cmd = (
        String("cd / 2>/dev/null; sysctl -n hw.memsize > '")
        + out_path
        + "' 2>/dev/null"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        var bytes = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                bytes = bytes * 10 + (c - 48)
                indig = True
            elif indig:
                break
        if not indig:
            return -1
        # Bytes → GiB (macOS reports hw.memsize as a power-of-two capacity, e.g.
        # a "24 GB" Mac is 25769803776 = 24 * 1024^3). Round to nearest whole GB.
        return (bytes + (1 << 29)) >> 30
    except:
        return -1


def _memory_used_pct() -> Int:
    """Instantaneous system memory-used % — App + Wired + Compressed over the total
    resident pages, from `vm_stat` (same subprocess-to-temp-file pattern as
    `_gpu_util_pct`; the bottom bar polls it beside the GPU sample). Returns -1 when
    unavailable so the bar can hide the indicator."""
    var out_path = _config_dir() + "/.mem_used"
    # `cd /` first (see `_gpu_util_pct`): guard against a wiped cwd after a re-unpack.
    var cmd = (
        String("cd / 2>/dev/null; vm_stat 2>/dev/null | awk '")
        + '/^Pages free/{v=$NF;gsub(/\\./,"",v);free=v}'
        + '/^Pages active/{v=$NF;gsub(/\\./,"",v);active=v}'
        + '/^Pages inactive/{v=$NF;gsub(/\\./,"",v);inactive=v}'
        + '/^Pages speculative/{v=$NF;gsub(/\\./,"",v);spec=v}'
        + '/^Pages wired/{v=$NF;gsub(/\\./,"",v);wired=v}'
        + '/occupied by compressor/{v=$NF;gsub(/\\./,"",v);comp=v}'
        + "END{total=free+active+inactive+spec+wired+comp;"
        + 'if(total>0)printf "%d",((active+wired+comp)*100/total)}'
        + "' > '"
        + out_path
        + "' 2>/dev/null"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        var cur = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                cur = cur * 10 + (c - 48)
                indig = True
            elif indig:
                break
        return cur if indig else -1
    except:
        return -1


# ── WebAuthn (Touch-ID) amount gate: single-file challenge + token stores ──────
# Single-user local app → one active challenge + one active token at a time is
# enough (both live in the data dir so they survive across worker threads). The
# challenge is single-use (deleted on verify); the token carries a ~5-min expiry.


def _is_demo() raises -> Bool:
    """The public replay demo (port 10010, or MILLFOLIO_DEMO set). Its transactions
    are SYNTHETIC + public-safe, and visitors have no Touch ID, so the amount gate is
    bypassed there (amounts always shown). Never true for the real product (:10000).
    """
    if String(getenv("MILLFOLIO_DEMO", "").strip()) != "":
        return True
    return _port() == 10010


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


def unauthorized(msg: String = "Unauthorized") -> Response:
    """A 401 (mirrors flare's `bad_request`)."""
    var resp = Response(
        status=401, reason="Unauthorized", body=List[UInt8](msg.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "application/json")
    except:
        pass
    return resp^


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


def _dir_size(path: String) -> Int:
    """Recursive byte size of a file or directory tree (0 if missing)."""
    try:
        if isfile(path):
            return getsize(path)
        if isdir(path):
            var total = 0
            var entries = listdir(path)
            for i in range(len(entries)):
                total += _dir_size(path + "/" + String(entries[i]))
            return total
    except:
        pass
    return 0


def _content_type(path: String) -> String:
    """Guess a Content-Type from the file extension. `.json` is checked before
    `.js` (".json" contains ".js")."""
    if path.find(".json") != -1:
        return String("application/json; charset=utf-8")
    if path.find(".js") != -1:
        return String("application/javascript; charset=utf-8")
    if path.find(".css") != -1:
        return String("text/css; charset=utf-8")
    if path.find(".svg") != -1:
        return String("image/svg+xml")
    if path.find(".html") != -1:
        return String("text/html; charset=utf-8")
    return String("application/octet-stream")


def _serve_file(path: String, content_type: String) raises -> Response:
    """Read a file under the web root and return it (404 if missing)."""
    var content: String
    try:
        with open(path, "r") as f:
            content = f.read()
    except:
        return not_found(path)
    var r = ok(content)
    try:
        r.headers.set("Content-Type", content_type)
    except:
        pass
    return r^


def _cors(var resp: Response) -> Response:
    """CORS scaffolding for the local web app (a different origin/port in dev).

    Deliberately does NOT set `Access-Control-Allow-Origin` — that is added by
    `Api.serve` *after* the origin has been allow-listed, so it echoes the
    specific caller origin instead of a wildcard `*`. A wildcard here would let
    ANY website the user visits read this API's responses (vault filenames,
    transactions, history) cross-origin; see `_host_allowed`."""
    try:
        resp.headers.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        resp.headers.set("Access-Control-Allow-Headers", "Content-Type")
    except:
        pass
    return resp^


def _forbidden(msg: String = "Forbidden") -> Response:
    """A 403 with NO CORS headers, so a cross-origin caller can't read the body.
    """
    var resp = Response(
        status=403, reason="Forbidden", body=List[UInt8](msg.as_bytes())
    )
    try:
        resp.headers.set("Content-Type", "text/plain")
    except:
        pass
    return resp^


def _extract_host(raw: String) -> String:
    """The bare host of a `Host`/`Origin` header value: strip the scheme, any
    path, IPv6 brackets, and the `:port`. `http://localhost:5173` → `localhost`,
    `[::1]:10000` → `::1`, `127.0.0.1:10000` → `127.0.0.1`."""
    var s = raw
    var sch = s.find("://")
    if sch != -1:
        s = String(s[byte = sch + 3 :])
    var slash = s.find("/")
    if slash != -1:
        s = String(s[byte=:slash])
    if s.startswith("["):
        var rb = s.find("]")
        if rb != -1:
            return String(s[byte=1:rb])
    var colon = s.find(":")
    if colon != -1:
        s = String(s[byte=:colon])
    return s^


def _host_allowed(h: String) raises -> Bool:
    """Is this host a loopback name we serve on? Empty (HTTP/1.0 / no header) is
    allowed — it isn't a browser DNS-rebinding vector. Extra hostnames (e.g. a
    Tailscale MagicDNS name for `mill start`'s `tailscale serve`) can be opted in
    via `MILLFOLIO_ALLOWED_HOSTS` (comma-separated)."""
    if h == "" or h == "localhost" or h == "127.0.0.1" or h == "::1":
        return True
    var extra = String(getenv("MILLFOLIO_ALLOWED_HOSTS", "").strip())
    if extra != "":
        var parts = extra.split(",")
        for i in range(len(parts)):
            if String(parts[i].strip()) == h:
                return True
    return False


def _tags_in_program(code: String) raises -> String:
    """The available category tag NAMES the generated program filters on —
    detected as a quoted literal (`"phone"`) alongside `.tags`. Comma-joined, in
    registry order; "" when the program used no tag (it read each transaction).
    """
    if code.find(".tags") == -1:
        return String("")
    var avail = effective_tags()
    var used = String("")
    for i in range(len(avail)):
        if code.find('"' + avail[i] + '"') != -1:
            if used.byte_length() > 0:
                used += ","
            used += avail[i]
    return used^


def _tag_proposal_in_program(code: String) raises -> List[String]:
    """A reusable-tag suggestion the model emitted as a program comment — so the next
    such question is a fast `.tags` filter instead of an inline classify. Two forms:
      `# SUGGEST_TAG: <name> = <kw>, <kw>`   → a KEYWORD rule (merchant-nameable)
      `# SUGGEST_TAG: <name> : <question>`   → an AI rule (semantic — reuse the yes/no
                                               question the model classified with)
    Returns `[name, value, kind]` (kind = `"ml"` or `"kw"`) when present, well-formed,
    and NOT already a known tag; `[]` otherwise. The separator that appears FIRST wins
    (an AI question may contain `=`; a keyword list won't contain `:`). Static scan —
    the comment never executes."""
    var lines = code.split("\n")
    var marker = String("# SUGGEST_TAG:")
    for i in range(len(lines)):
        var ln = String(lines[i].strip())
        if not ln.startswith(marker):
            continue
        var rest = String(ln.removeprefix(marker).strip())
        var eq = rest.find("=")
        var colon = rest.find(":")
        var is_ml = colon != -1 and (eq == -1 or colon < eq)
        var sep = ":" if is_ml else "="
        var cut = rest.find(sep)
        if cut <= 0:
            continue
        var name = String(String(rest[byte=:cut]).strip())
        var value = String(String(rest[byte = cut + 1 :]).strip())
        if name.byte_length() == 0 or value.byte_length() == 0:
            continue
        # Skip a suggestion for a tag that already exists (redundant).
        var avail = effective_tags()
        var dup = False
        for a in range(len(avail)):
            if avail[a] == name:
                dup = True
                break
        if dup:
            continue
        var out = List[String]()
        out.append(name^)
        out.append(value^)
        out.append(String("ml") if is_ml else String("kw"))
        return out^
    return List[String]()


@fieldwise_init
struct Api(Copyable, Handler, Movable):
    var st: UnsafePointer[MillfolioState, MutUntrackedOrigin]

    def serve(self, req: Request) raises -> Response:
        """Anti-CSRF / anti-DNS-rebinding gate in front of `_route`.

        This server holds personal financial data on a loopback port that ANY
        browser tab or local process on the machine can reach. Two checks close
        that off before any handler runs:
          • `Host` must be a loopback name — defeats DNS rebinding (attacker.com
            rebound to 127.0.0.1 arrives with `Host: attacker.com`).
          • `Origin`, when present, must be loopback — defeats a malicious site
            issuing cross-origin `fetch`/WebSocket reads or CSRF POSTs.
        A rejected request gets a 403 with no CORS headers, so its body is
        unreadable cross-origin either way. Allowed origins are echoed back
        (not `*`) so the browser only shares responses with local callers.

        SKIPPED in demo mode: the public demo (port 10010, behind a Cloudflare
        Tunnel) is served under a real hostname, not loopback, and holds only
        SYNTHETIC data behind a Turnstile bot gate — the personal-vault threat
        this guard defends against doesn't exist there."""
        var origin_raw = String(req.headers.get("origin"))
        if not _is_demo():
            var host = _extract_host(String(req.headers.get("host")))
            if not _host_allowed(host):
                return _forbidden("host not allowed")
            if origin_raw != "" and not _host_allowed(
                _extract_host(origin_raw)
            ):
                return _forbidden("origin not allowed")
        var resp = self._route(req)
        if origin_raw != "":
            try:
                resp.headers.set("Access-Control-Allow-Origin", origin_raw)
                resp.headers.set("Vary", "Origin")
            except:
                pass
        return resp^

    def _route(self, req: Request) raises -> Response:
        var path = req.url
        # CORS preflight (compare the raw method string — no Method.OPTIONS dep).
        if req.method == "OPTIONS":
            return _cors(Response(status=204, reason="No Content"))
        if req.method == Method.POST and path == "/chat":
            return self.handle_chat(req)
        if path == "/api/vault":
            return self.handle_vault()
        # Document viewer: /api/doc?alias=file_N streams the raw indexed file
        # (alias-gated via the manifest — no caller-supplied path, so no traversal).
        if path == "/api/doc" or (path.find("/api/doc?") == 0):
            return self.handle_doc(req)
        if req.method == Method.POST and path == "/api/search":
            return self.handle_search(req)
        if path == "/health":
            return _cors(ok("millfolio ok"))
        # The on-device model name — the UI shows it in the bottom bar.
        if path == "/api/model":
            # `turnstile_sitekey` is non-empty only when the demo gate is active — the
            # client renders the widget iff it's present.
            var sitekey = (
                _turnstile_sitekey() if _turnstile_enabled() else String("")
            )
            return _cors(
                ok_json(
                    '{"model":'
                    + json_escape(_model_label())
                    + ',"version":'
                    + json_escape(_app_version())
                    + ',"turnstile_sitekey":'
                    + json_escape(sitekey)
                    + "}"
                )
            )
        # On-device model selector: the list of switchable (cached) models + the
        # current selection; POST /api/models/select switches it (restarts engine).
        if path == "/api/models":
            return _cors(
                ok_json(
                    '{"current":'
                    + json_escape(_current_model_id())
                    + ',"loaded":'
                    + json_escape(_engine_loaded_model())
                    + ',"memoryGb":'
                    + String(_memory_gb())
                    + ',"available":'
                    + _available_models_json()
                    + "}"
                )
            )
        if req.method == Method.POST and path == "/api/models/select":
            return self.handle_model_select(req)
        # Model catalog downloads: start a background fetch of a supported model's
        # weights, and poll its progress.
        if req.method == Method.POST and path == "/api/models/download":
            return self.handle_model_download(req)
        if path == "/api/models/download/status":
            return _cors(ok_json(_download_status_json()))
        # First-run onboarding: fetch + index the hosted sample vault so a new user
        # can try millfolio without pointing it at their own folder. Poll its progress.
        if req.method == Method.POST and path == "/api/demo/download":
            return self.handle_demo_download()
        if path == "/api/demo/status":
            return _cors(ok_json(_demo_status_json()))
        # Vault/Files: index an arbitrary local folder/file, track it, and re-index
        # tracked folders to pick up new files. One job at a time (shared with the
        # sample-vault import path). See handle_index for the append-not-clobber note.
        if req.method == Method.POST and path == "/api/index":
            return self.handle_index(req)
        if path == "/api/index/status":
            return _cors(ok_json(_index_status_json()))
        if path == "/api/index/folders":
            return _cors(ok_json(_tracked_folders_json()))
        if req.method == Method.POST and path == "/api/index/reindex":
            return self.handle_index_reindex(req)
        if req.method == Method.POST and path == "/api/index/folders/remove":
            return self.handle_index_folder_remove(req)
        # Demo bot gate: validate a Turnstile token → mint a demo-access token the
        # client echoes on WS chat frames. No-op (empty token) when Turnstile is off.
        if req.method == Method.POST and path == "/api/demo/verify":
            return self.handle_demo_verify(req)
        # Instantaneous GPU utilization (%); the bottom bar keeps a 30s average.
        if path == "/api/gpu":
            return _cors(
                ok_json(
                    '{"util":'
                    + String(_gpu_util_pct())
                    + ',"mem":'
                    + String(_memory_used_pct())
                    + "}"
                )
            )
        # Accumulated per-question usage (JSONL file, returned verbatim) — the Stats page.
        if path == "/api/stats":
            return self.handle_stats()
        if path == "/api/history/delete":
            return self.handle_history_delete(req)
        if path == "/api/history":
            return self.handle_history()
        if path == "/api/system":
            return self.handle_system()
        # Category tags: the panel's list (names + keywords + per-tag counts) and
        # the editable registry file. All in-process via vault.derive.store.
        if path == "/api/tags":
            return self.handle_tags()
        if path == "/api/transactions" or path.find("/api/transactions?") == 0:
            return self.handle_transactions(req)
        # WebAuthn (Touch-ID) gate for revealing transaction amounts.
        if req.method == Method.POST and path == "/api/auth/unlock":
            return self.handle_auth_unlock(req)
        if req.method == Method.POST and path == "/api/amounts/unlock-local":
            return self.handle_amounts_unlock_local(req)
        if path == "/api/categories/preview":
            return self.handle_categories_preview(req)
        if path == "/api/categories":
            if req.method == Method.POST:
                return self.handle_categories_save(req)
            return self.handle_categories_get()
        if path == "/api/backfill/status":
            return self.handle_backfill_status()
        if path == "/api/backfill/run":
            return self.handle_backfill_run()
        if path == "/api/backfill/pause":
            return self.handle_backfill_pause(req)
        if path == "/api/backfill/resume":
            return self.handle_backfill_resume()
        if path == "/api/backfill/priority":
            return self.handle_backfill_priority(req)
        if path == "/api/tags/preview-ai":
            return self.handle_tags_preview_ai(req)
        if path == "/api/tags/add":
            return self.handle_tags_add(req)
        # Static web UI — same-origin in production (Vite serves it in dev).
        # Reject path traversal before mapping under web/dist.
        if path.find("..") == -1:
            var root = _web_root()
            if path == "/" or path == "/index.html":
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
            # A client-side route (no file extension, e.g. /stats) → serve the SPA
            # entry so SvelteKit's router can render it (adapter-static fallback).
            if path.find(".") == -1:
                return _serve_file(
                    root + "/index.html", "text/html; charset=utf-8"
                )
            # Any other path is a built asset — SvelteKit emits /_app/immutable/…
            # (JS/CSS), /_app/version.json, /favicon.svg, etc. Serve it from the web
            # root (404 only if it genuinely isn't there).
            return _serve_file(root + path, _content_type(path))
        return _cors(not_found(path))

    def handle_chat(self, req: Request) raises -> Response:
        ref s = self.st[]
        var msg = _extract_message(req.text())
        if msg == "":
            return _cors(bad_request('{"reply":"(empty message)"}'))
        print("  chat: ", msg, sep="")
        var reply: String
        try:
            # VAULT-ONLY: always the private-vault codegen loop over the vault dir.
            reply = s.orch.run_vault_task(msg, s.vault_dir.copy())
        except e:
            reply = String("error: ") + String(e)
        return _cors(ok_json('{"reply":' + _json_escape(reply) + "}"))

    def handle_stats(self) raises -> Response:
        """Return the usage log as {"model": <label>, "records": [<obj>, …]}. The file
        is JSONL (each line is already a valid object), so we comma-join the non-empty
        lines into an array — no server-side JSON parsing. Missing file → empty list.
        """
        var recs = String("")
        var first = True
        try:
            var raw: String
            with open(_stats_path(), "r") as f:
                raw = f.read()
            var lines = raw.split("\n")
            for i in range(len(lines)):
                var ln = String(lines[i]).strip()
                if ln.byte_length() == 0:
                    continue
                if not first:
                    recs += ","
                recs += ln
                first = False
        except:
            pass
        return _cors(
            ok_json(
                '{"model":'
                + json_escape(_model_label())
                + ',"records":['
                + recs
                + '],"backfill":'
                + backfill_dedup_json()
                + "}"
            )
        )

    def handle_history(self) raises -> Response:
        """Return the full ask history as {"records": [<obj>, …]} — the durable
        backend store (`asks.jsonl`) of every question with its generated program
        and answer. JSONL, so we comma-join the non-empty lines into an array — no
        server-side JSON parsing. Missing file → empty list. Newest first so the UI
        panel shows the most recent ask at the top."""
        var raw = String("")
        try:
            with open(_asks_path(), "r") as f:
                raw = f.read()
        except:
            pass  # missing file → empty history
        return _cors(ok_json('{"records":' + history_records_array(raw) + "}"))

    def handle_history_delete(self, req: Request) raises -> Response:
        """POST /api/history/delete {"q": …} → remove that question's records from
        the durable `asks.jsonl` (the recent-questions panel dedups by question, so
        this deletes the entry for good). Missing file / empty q is a no-op success.
        Returns {"ok":true}."""
        var q: String
        try:
            var j = loads(req.text())
            q = j["q"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {q}"}'))
        if q == "":
            return _cors(ok_json('{"ok":true}'))
        var raw: String
        try:
            with open(_asks_path(), "r") as f:
                raw = f.read()
        except:
            return _cors(ok_json('{"ok":true}'))  # nothing to delete
        var filtered = delete_ask_records(raw, q)
        try:
            with open(_asks_path(), "w") as f:
                f.write(filtered)
        except:
            return _cors(bad_request('{"error":"could not update history"}'))
        return _cors(ok_json('{"ok":true}'))

    def handle_system(self) raises -> Response:
        """System info for the System tab: WHERE the data + logs live, so a user can
        find a per-ask transcript (the generated program + its run output) when an
        answer looks wrong, plus the running version/model. Paths are computed from
        $HOME so they stay correct across machines; the log locations mirror the ones
        the `mill` CLI's launch agents write to."""
        return _cors(
            ok_json(
                system_json(
                    getenv("HOME", ""),
                    _app_version(),
                    _model_label(),
                    _config_dir(),
                    _stats_path(),
                    _asks_path(),
                )
            )
        )

    def handle_tags(self) raises -> Response:
        """GET /api/tags → {"tags":[{name,keywords,count}]} for the Tags panel —
        in-process (vault.derive.store), the SAME payload `millfolio tags --json`
        prints. No engine spawn."""
        return _cors(ok_json(tags_report_json()))

    # ── amount-reveal gate (passphrase) ───────────────────────────────────────

    def handle_auth_unlock(self, req: Request) raises -> Response:
        """POST /api/auth/unlock {password} → if it matches the local reveal
        passphrase (`amount_password`, look it up with `mill get amount-password`),
        mint a ~15-min bearer token that unlocks `?amounts=1`. 401 on a wrong
        passphrase. The check + the secret live server-side, so this genuinely gates
        the amounts (a curl without a valid token gets `amount:null`)."""
        var candidate: String
        try:
            var j = loads(req.text())
            candidate = j["password"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {password}"}'))
        if not verify_amount_password(candidate):
            return _cors(unauthorized('{"error":"wrong passphrase"}'))
        return _cors(ok_json('{"token":"' + _mint_reveal_token() + '"}'))

    def handle_amounts_unlock_local(self, req: Request) raises -> Response:
        """POST /api/amounts/unlock-local → the NATIVE local-capability path. The
        macOS menu-bar app, after a successful `LAContext` Touch-ID / login-password
        check, reads the `.reveal-secret` file and presents it here (JSON `{secret}`
        or the `X-Millfolio-Reveal-Secret` header). On a constant-time match we mint
        the SAME reveal token the passphrase path mints — so amounts unlock identically.
        Localhost-only (rides the Tier-1 loopback guard in `_route`). DENIED in the
        demo (its amounts are already public → no gate to bridge). The passphrase
        endpoint is untouched, so a browser with no native bridge is unaffected.
        """
        if _is_demo():
            return _forbidden('{"error":"not available in demo"}')
        var presented = String(req.headers.get("x-millfolio-reveal-secret"))
        if presented == "":
            try:
                var j = loads(req.text())
                presented = j["secret"].string_value()
            except:
                presented = String("")
        var secret = _ensure_reveal_secret()
        if (
            secret == ""
            or presented == ""
            or not _const_time_eq(presented, secret)
        ):
            return _cors(unauthorized('{"error":"bad local secret"}'))
        return _cors(ok_json('{"token":"' + _mint_reveal_token() + '"}'))

    def handle_demo_verify(self, req: Request) raises -> Response:
        """POST /api/demo/verify {token} → validate the Turnstile token with Cloudflare
        siteverify; on success mint a demo-access token the client echoes on WS chat
        frames. When the gate is OFF (not demo / no secret), return ok with an empty
        token so the client flow is a harmless no-op."""
        if not _turnstile_enabled():
            return _cors(ok_json('{"ok":true,"token":""}'))
        var token: String
        try:
            var j = loads(req.text())
            token = j["token"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {token}"}'))
        if not _verify_turnstile(token):
            return _cors(
                unauthorized('{"error":"turnstile verification failed"}')
            )
        return _cors(
            ok_json('{"ok":true,"token":"' + _mint_demo_token() + '"}')
        )

    def _reveal_authorized(self, req: Request) raises -> Bool:
        """True iff the request carries a valid, unexpired reveal token
        (`Authorization: Bearer <token>`) matching the one minted by unlock."""
        var auth = String(req.headers.get("authorization"))
        if not auth.startswith("Bearer "):
            return False
        var tok = String(auth.removeprefix("Bearer ").strip())
        if tok == "" or not exists(_reveal_token_path()):
            return False
        var line: String
        with open(_reveal_token_path(), "r") as f:
            line = f.read()
        var parts = line.split(" ")
        if len(parts) < 2 or String(parts[0].strip()) != tok:
            return False
        return _epoch_s() < Int64(atol(String(parts[1].strip())))

    def handle_transactions(self, req: Request) raises -> Response:
        """GET /api/transactions → {"transactions":[{file,date,year,amount,direction,
        desc,tags}]} — the exact reconciled rows, each with its derived category tags.
        The amounts are WITHHELD (`amount:null`) unless `?amounts=1` AND the request
        carries a valid Touch-ID reveal token — so the figures never reach the browser
        until the gate is passed. In-process via vault.derive.store; no engine spawn.
        """
        var inc = _is_demo() or (
            req.query_param("amounts") == "1" and self._reveal_authorized(req)
        )
        return _cors(ok_json(transactions_json(inc)))

    def handle_categories_get(self) raises -> Response:
        """GET /api/categories → {"text": <raw categories.txt>} for the editor
        (the file is seeded with the built-in defaults if absent)."""
        return _cors(ok_json('{"text":' + json_escape(read_categories()) + "}"))

    def handle_categories_save(self, req: Request) raises -> Response:
        """POST /api/categories {"text": …} → overwrite categories.txt (it becomes
        the user's authoritative registry) and re-tag the stored transactions
        in-process. Returns {"ok":true,"retagged":N}."""
        var text: String
        try:
            var j = loads(req.text())
            text = j["text"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {text}"}'))
        var changed = save_categories(text)
        return _cors(ok_json('{"ok":true,"retagged":' + String(changed) + "}"))

    def handle_categories_preview(self, req: Request) raises -> Response:
        """POST /api/categories/preview {"text": …} → dry-run the edited rules over
        the stored transactions WITHOUT saving (the validation loop): per-tag match
        counts + a few example descriptions to spot false positives before saving.
        Returns {"tags":[{name,ml,count,examples}]} from preview_categories."""
        var text: String
        try:
            var j = loads(req.text())
            text = j["text"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {text}"}'))
        return _cors(ok_json(preview_categories(text)))

    def handle_backfill_status(self) raises -> Response:
        """GET /api/backfill/status → per-AI-tag backfill progress
        (`{status,paused_until,perTag:[…],pendingTotal}`) for the Tags-tab
        Backfill panel. Lock-free read; no engine call."""
        return _cors(ok_json(backfill_status_json()))

    def handle_backfill_run(self) raises -> Response:
        """POST /api/backfill/run → run ONE bounded backfill slice (a
        generation-batch) via the on-device engine, then return the fresh status.
        The UI loops this until `pendingTotal` hits 0, so each call stays short and
        shows progress. Non-blocking try-lock inside → returns changed:0 when
        another writer holds it or backfill is paused."""
        var changed = 0
        try:
            changed = ml_backfill_slice(_engine_url())
        except e:
            # Engine down / chat model not serving → best-effort, report 0 + status.
            print("  backfill slice skipped: ", String(e), sep="")
        return _cors(
            ok_json(
                '{"ok":true,"changed":'
                + String(changed)
                + ',"status":'
                + backfill_status_json()
                + "}"
            )
        )

    def handle_backfill_pause(self, req: Request) raises -> Response:
        """POST /api/backfill/pause {"seconds":N} → pause the between-questions
        worker for N seconds (auto-resumes when it elapses). Returns the status.
        """
        var seconds: Int
        try:
            var j = loads(req.text())
            seconds = Int(j["seconds"].int_value())
        except:
            return _cors(bad_request('{"error":"expected {seconds}"}'))
        set_pause(seconds)
        return _cors(
            ok_json('{"ok":true,"status":' + backfill_status_json() + "}")
        )

    def handle_backfill_resume(self) raises -> Response:
        """POST /api/backfill/resume → clear any pause (resume now)."""
        set_pause(0)
        return _cors(
            ok_json('{"ok":true,"status":' + backfill_status_json() + "}")
        )

    def handle_backfill_priority(self, req: Request) raises -> Response:
        """POST /api/backfill/priority {"priority":"high"|"medium"|"low"} → set the
        background backfiller's throttle. Low naps ~5s between classify slices (GPU
        mostly free), high ~0.1s (fastest). Returns the fresh status (with priority).
        """
        var p: String
        try:
            var j = loads(req.text())
            p = j["priority"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {priority}"}'))
        set_priority(p)
        return _cors(
            ok_json('{"ok":true,"status":' + backfill_status_json() + "}")
        )

    def handle_tags_preview_ai(self, req: Request) raises -> Response:
        """POST /api/tags/preview-ai {"prompt":…} → time-boxed (~5s) preview of an
        AI rule over the stored transactions, WITHOUT persisting anything. Returns
        {matched, evaluated, total} so the UI can show "≈N records would match"
        before the user creates the tag."""
        var prompt: String
        try:
            var j = loads(req.text())
            prompt = j["prompt"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {prompt}"}'))
        if String(prompt.strip()) == "":
            return _cors(bad_request('{"error":"empty prompt"}'))
        try:
            return _cors(ok_json(preview_ml_json(_engine_url(), prompt)))
        except e:
            return _cors(
                bad_request(
                    '{"error":"preview failed — is the engine up? '
                    + _json_escape(String(e))
                    + '"}'
                )
            )

    def handle_model_select(self, req: Request) raises -> Response:
        """POST /api/models/select {"model": "<hf-id>"} → switch the on-device model.
        Rewrites the engine config's `model` and restarts the engine LaunchAgent (a
        few seconds of reload). Only cached models are accepted, and never in the
        public demo (it would restart the shared engine). Returns {"ok":true,"model"}.
        """
        if _is_demo():
            return _cors(
                unauthorized(
                    '{"error":"model switching is disabled in the demo"}'
                )
            )
        var id: String
        try:
            id = String(loads(req.text())["model"].string_value())
        except:
            return _cors(bad_request('{"error":"expected {model}"}'))
        if id == "":
            return _cors(bad_request('{"error":"empty model"}'))
        # Only allow a model that (a) appears in the catalog/available list AND (b) is
        # actually DOWNLOADED, so we never restart the engine into a checkpoint that's
        # missing (the available list now includes not-yet-downloaded catalog models).
        if _available_models_json().find(json_escape(id)) == -1:
            return _cors(bad_request('{"error":"unknown model"}'))
        if not _model_downloaded(id):
            return _cors(
                bad_request('{"error":"that model isn\'t downloaded yet"}')
            )
        if not _config_set_model(id):
            return _cors(
                bad_request('{"error":"could not update engine config"}')
            )
        _restart_engine()
        return _cors(ok_json('{"ok":true,"model":' + json_escape(id) + "}"))

    def handle_model_download(self, req: Request) raises -> Response:
        """POST /api/models/download {"model": "<hf-id>"} → start a background download
        of a SUPPORTED chat model's weights via the native downloader. Rejects unknown
        ids, a second concurrent download, and the public demo (no downloads there).
        Returns {"ok":true,"model"}; the client polls /api/models/download/status.
        """
        if _is_demo():
            return _cors(
                unauthorized('{"error":"downloads are disabled in the demo"}')
            )
        var id: String
        try:
            id = String(loads(req.text())["model"].string_value())
        except:
            return _cors(bad_request('{"error":"expected {model}"}'))
        if id == "":
            return _cors(bad_request('{"error":"empty model"}'))
        if not _is_supported(id):
            return _cors(
                bad_request('{"error":"unknown or unsupported model"}')
            )
        if _model_downloaded(id):
            return _cors(
                ok_json(
                    '{"ok":true,"downloaded":true,"model":'
                    + json_escape(id)
                    + "}"
                )
            )
        if _download_running():
            return _cors(
                bad_request('{"error":"a download is already in progress"}')
            )
        if not _start_download_detached(id):
            return _cors(
                bad_request(
                    '{"error":"downloads unavailable (downloader not'
                    ' configured)"}'
                )
            )
        return _cors(ok_json('{"ok":true,"model":' + json_escape(id) + "}"))

    def handle_demo_download(self) raises -> Response:
        """POST /api/demo/download → download the hosted sample vault
        (MILLFOLIO_DEMO_URL, default https://millfolio.app/demo-vault.zip), unpack
        it into `<data>/demo-vault/`, and index it so its docs + transactions become
        queryable — all as a DETACHED background job the client polls via
        /api/demo/status. Idempotent: a finished import no-ops to done. Disabled in
        the public replay demo (its vault is fixed + synthetic). Indexing needs the
        engine runner (MILLFOLIO_RUN_SCRIPT), so we 400 when it isn't configured.
        """
        if _is_demo():
            return _cors(
                unauthorized('{"error":"sample data is disabled in the demo"}')
            )
        if getenv("MILLFOLIO_RUN_SCRIPT", "") == "":
            return _cors(
                bad_request(
                    '{"error":"sample data unavailable (engine runner not'
                    ' configured)"}'
                )
            )
        # Already imported → no-op to done (don't re-download a present vault).
        if _demo_present() and _demo_read_state() == "done":
            return _cors(ok_json('{"ok":true,"state":"done"}'))
        if _demo_running():
            return _cors(
                bad_request('{"error":"sample data import already running"}')
            )
        if not _start_demo_detached():
            return _cors(
                bad_request('{"error":"could not start sample data import"}')
            )
        return _cors(ok_json('{"ok":true,"state":"downloading"}'))

    def handle_index(self, req: Request) raises -> Response:
        """POST /api/index {"path":…} → index an arbitrary local folder or file as a
        DETACHED background job (polled via /api/index/status), and TRACK the path so
        it can be re-indexed later.

        APPEND-not-clobber: the on-device indexer keys its ENTIRE store on the
        common-ancestor directory of the paths it's handed, and rebuilds from scratch
        whenever that base changes — so indexing a lone new folder would REPLACE the
        previously-indexed one. We therefore always index the UNION of every tracked
        path in one run; the content-hash diff skips unchanged files, so re-indexing
        the union to add one folder stays cheap. (Adding a folder that shifts the
        common ancestor still forces a full re-embed — no data loss, just slower.)

        Disabled in the demo; needs the engine runner (MILLFOLIO_RUN_SCRIPT). One job
        at a time (rejects a second while one runs)."""
        if _is_demo():
            return _cors(
                unauthorized('{"error":"indexing is disabled in the demo"}')
            )
        if getenv("MILLFOLIO_RUN_SCRIPT", "") == "":
            return _cors(
                bad_request(
                    '{"error":"indexing unavailable (engine runner not'
                    ' configured)"}'
                )
            )
        var raw: String
        try:
            var j = loads(req.text())
            raw = j["path"].string_value()
        except:
            return _cors(bad_request('{"error":"expected {path}"}'))
        var p = String(raw.strip())
        if p == "":
            return _cors(bad_request('{"error":"empty path"}'))
        # A newline/CR would let the path break out of the shell command below.
        if p.find("\n") != -1 or p.find("\r") != -1:
            return _cors(bad_request('{"error":"invalid path"}'))
        if not exists(p):
            return _cors(
                bad_request(
                    '{"error":"path not found","path":' + json_escape(p) + "}"
                )
            )
        if _index_running():
            return _cors(
                bad_request('{"error":"an index job is already running"}')
            )
        # Union of the already-tracked paths + this one (dedup, order-preserving).
        var union = _read_tracked_paths()
        var seen = False
        for i in range(len(union)):
            if union[i] == p:
                seen = True
                break
        if not seen:
            union.append(p.copy())
        if not _start_index_detached(union):
            return _cors(bad_request('{"error":"could not start indexing"}'))
        return _cors(ok_json('{"ok":true,"state":"indexing"}'))

    def handle_index_reindex(self, req: Request) raises -> Response:
        """POST /api/index/reindex {"path"?:…} → re-run indexing to pick up new/changed
        files. Whether a specific `path` is given or not, the WHOLE union of tracked
        paths is re-indexed (see handle_index: indexing a subset would clobber the
        rest); a given `path` must be one of the tracked ones. No-op error when nothing
        is tracked yet."""
        if _is_demo():
            return _cors(
                unauthorized('{"error":"indexing is disabled in the demo"}')
            )
        if getenv("MILLFOLIO_RUN_SCRIPT", "") == "":
            return _cors(
                bad_request(
                    '{"error":"indexing unavailable (engine runner not'
                    ' configured)"}'
                )
            )
        if _index_running():
            return _cors(
                bad_request('{"error":"an index job is already running"}')
            )
        var tracked = _read_tracked_paths()
        if len(tracked) == 0:
            return _cors(bad_request('{"error":"no tracked folders to re-index"}'))
        # An explicit `path`, when present, must be tracked (we still index the union).
        try:
            var j = loads(req.text())
            var want = String(j["path"].string_value().strip())
            if want != "":
                var ok = False
                for i in range(len(tracked)):
                    if tracked[i] == want:
                        ok = True
                        break
                if not ok:
                    return _cors(
                        bad_request('{"error":"path is not tracked"}')
                    )
        except:
            pass  # no/empty body → re-index all tracked
        if not _start_index_detached(tracked):
            return _cors(bad_request('{"error":"could not start indexing"}'))
        return _cors(ok_json('{"ok":true,"state":"indexing"}'))

    def handle_index_folder_remove(self, req: Request) raises -> Response:
        """POST /api/index/folders/remove {"path":…} → stop TRACKING a folder. This
        only forgets the path (so it's no longer re-indexed); the already-embedded
        chunks stay in the index until the next full re-index rebuilds the store from
        the remaining tracked paths. Returns the updated list."""
        var p: String
        try:
            var j = loads(req.text())
            p = String(j["path"].string_value().strip())
        except:
            return _cors(bad_request('{"error":"expected {path}"}'))
        if p == "":
            return _cors(bad_request('{"error":"empty path"}'))
        var cur = _read_tracked()
        var keep_paths = List[String]()
        var keep_epochs = List[String]()
        for i in range(len(cur.paths)):
            if cur.paths[i] != p:
                keep_paths.append(cur.paths[i].copy())
                keep_epochs.append(cur.epochs[i].copy())
        _write_tracked(keep_paths, keep_epochs)
        return _cors(ok_json(_tracked_folders_json()))

    def handle_tags_add(self, req: Request) raises -> Response:
        """POST /api/tags/add {"name":…, "prompt"?:…, "keywords"?:…} → append a new
        category rule (AI rule when `prompt` is set, else a keyword rule) to
        categories.txt and re-tag. Returns {"ok":true,"retagged":N}. An AI rule
        backfills afterwards via the worker / Backfill now."""
        var name: String
        var prompt: String
        var keywords: String
        try:
            var j = loads(req.text())
            name = j["name"].string_value()
            try:
                prompt = j["prompt"].string_value()
            except:
                prompt = String("")
            try:
                keywords = j["keywords"].string_value()
            except:
                keywords = String("")
        except:
            return _cors(
                bad_request('{"error":"expected {name, prompt|keywords}"}')
            )
        if String(name.strip()) == "":
            return _cors(bad_request('{"error":"empty name"}'))
        var changed = add_category(name, keywords, prompt)
        return _cors(ok_json('{"ok":true,"retagged":' + String(changed) + "}"))

    def handle_vault(self) raises -> Response:
        """The vault view: the INDEXED files + index stats, read from the engine's
        manifest.tsv (written by `mill index`). Reflects what was actually indexed
        — not a live walk of the served dir — so it's correct even when the indexed
        folder differs from the served vault dir (both are surfaced, plus a
        `dirMismatch` flag the UI can warn on). Read-only."""
        ref s = self.st[]
        var served_dir = s.vault_dir.copy()
        var config_dir = _config_dir()
        var manifest_path = config_dir + "/manifest.tsv"
        var db_path = config_dir + "/index.db"

        var indexed = isfile(manifest_path)
        var source_dir = String("")
        var files_json = String("[")
        var file_count = 0
        var total_chunks = 0
        if indexed:
            var text: String
            with open(manifest_path, "r") as f:
                text = f.read()
            var lines = text.split("\n")
            for i in range(len(lines)):
                var line = String(lines[i])
                if line.byte_length() == 0:
                    continue
                var cols = line.split("\t")
                # Meta row: #meta <next_id> <next_alias> <source_dir>.
                if String(cols[0]) == "#meta":
                    if len(cols) >= 4:
                        source_dir = _tsv_unescape(String(cols[3]))
                    continue
                # File row: alias name kind size sha256 id_start chunk_count.
                if len(cols) < 7:
                    continue
                var falias = String(cols[0])
                var name = _tsv_unescape(String(cols[1]))
                var kind = String(cols[2])
                var sz = _atoi(String(cols[3]))
                var chunks = _atoi(String(cols[6]))
                total_chunks += chunks
                if file_count > 0:
                    files_json += ","
                files_json += "{"
                files_json += '"alias":' + _json_escape(falias) + ","
                files_json += '"name":' + _json_escape(name) + ","
                files_json += '"kind":' + _json_escape(kind) + ","
                files_json += '"sizeBytes":' + String(sz) + ","
                files_json += '"chunks":' + String(chunks)
                files_json += "}"
                file_count += 1
        files_json += "]"

        var has_index = indexed and file_count > 0
        var mismatch = (
            has_index and source_dir != "" and source_dir != served_dir
        )

        var out = String("{")
        out += '"vaultDir":' + _json_escape(served_dir) + ","
        out += '"sourceDir":' + _json_escape(source_dir) + ","
        out += '"dirMismatch":' + ("true" if mismatch else "false") + ","
        out += '"configDir":' + _json_escape(config_dir) + ","
        out += '"indexed":' + ("true" if has_index else "false") + ","
        out += '"embeddingDim":' + String(EMBED_DIM) + ","
        out += '"fileCount":' + String(file_count) + ","
        out += '"indexedFileCount":' + String(file_count) + ","
        out += '"chunkCount":' + String(total_chunks) + ","
        out += '"dbSizeBytes":' + String(_dir_size(db_path)) + ","
        out += '"files":' + files_json
        out += "}"
        return _cors(ok_json(out))

    def handle_doc(self, req: Request) raises -> Response:
        """Stream a single indexed document for the in-app viewer:
        GET /api/doc?alias=file_N -> the raw file bytes, Content-Type by kind
        (application/pdf / text/csv / text/markdown) so the browser renders it
        inline. FRONTIER-SAFE: the caller passes only the manifest alias; we map
        it to the real path from manifest.tsv (#meta source_dir + the file's
        name). The caller never supplies a path, so there's no traversal — an
        unknown alias is a 404, never a read outside the indexed dir."""
        var want = req.query_param("alias")
        if want == "":
            return _cors(bad_request("missing alias"))
        var manifest_path = _config_dir() + "/manifest.tsv"
        if not isfile(manifest_path):
            return _cors(not_found("no index"))
        var text: String
        with open(manifest_path, "r") as f:
            text = f.read()
        # Resolve alias -> (source_dir, name, kind) from the manifest.
        var source_dir = String("")
        var name = String("")
        var kind = String("")
        var lines = text.split("\n")
        for i in range(len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var cols = line.split("\t")
            if String(cols[0]) == "#meta":
                if len(cols) >= 4:
                    source_dir = _tsv_unescape(String(cols[3]))
                continue
            if len(cols) < 7:
                continue
            if String(cols[0]) == want:
                name = _tsv_unescape(String(cols[1]))
                kind = String(cols[2])
        if name == "":
            return _cors(not_found("unknown alias"))

        var file_path = source_dir + "/" + name
        var data: List[UInt8]
        try:
            with open(file_path, "r") as f:
                data = f.read_bytes()
        except:
            return _cors(not_found(name))

        var ctype = String("application/octet-stream")
        if kind == "pdf":
            ctype = String("application/pdf")
        elif kind == "csv":
            ctype = String("text/csv; charset=utf-8")
        elif kind == "md":
            ctype = String("text/markdown; charset=utf-8")
        elif kind == "docx":
            # Browsers can't render .docx inline — the viewer's "Open ↗" downloads it.
            ctype = String(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        var r = Response(status=200, reason="OK", body=data^)
        try:
            r.headers.set("Content-Type", ctype)
            # inline -> render in the viewer rather than triggering a download.
            r.headers.set(
                "Content-Disposition", 'inline; filename="' + name + '"'
            )
        except:
            pass
        return _cors(r^)

    def handle_search(self, req: Request) raises -> Response:
        """Semantic vault search: POST {"query": ..., "k": N} -> {"hits":[{alias,
        score,text}]}. The LanceDB/embedding work stays OUT of this server — we
        shell the `millfolio` engine binary via its run-script (MILLFOLIO_RUN_SCRIPT,
        set by the launcher) and have it write the JSON to a file (so captured
        stderr noise can't corrupt it), then return that file's contents."""
        var query: String
        var k = 5
        try:
            var j = loads(req.text())
            query = j["query"].string_value()
            try:
                k = Int(j["k"].int_value())
            except:
                k = 5
        except:
            query = String("")
        if query == "":
            return _cors(bad_request('{"error":"empty query","hits":[]}'))
        var run_script = getenv("MILLFOLIO_RUN_SCRIPT", "")
        if run_script == "":
            return _cors(
                ok_json(
                    '{"error":"search unavailable — engine runner not'
                    ' configured","hits":[]}'
                )
            )

        var cfg = _config_dir()
        var out_json = cfg + "/.search_out.json"
        var cap = cfg + "/.search_cap.txt"
        var argv = List[String]()
        argv.append(String("/bin/bash"))
        argv.append(run_script)
        argv.append(String("search"))
        argv.append(query)
        argv.append(String(k))
        argv.append(String("--json"))
        argv.append(String("--out"))
        argv.append(out_json)
        var rc = _spawn_capture(argv, cap)
        if rc != 0:
            return _cors(
                ok_json(
                    '{"error":"search failed (exit '
                    + String(rc)
                    + ')","hits":[]}'
                )
            )
        var hits: String
        try:
            with open(out_json, "r") as f:
                hits = f.read()
        except:
            hits = String("[]")
        return _cors(ok_json('{"hits":' + hits + "}"))


def _usleep(usec: Int):
    """Sleep `usec` microseconds (libc usleep) — the gap between run-output polls
    in the streaming loop, so we don't busy-spin while the sandboxed child runs.
    """
    _ = external_call["usleep", Int](Int(usec))


def _backfill_worker(arg: _OpaquePtr) -> _OpaquePtr:
    """Detached background thread — drains pending AI-tag backfill in bounded
    slices so an AI tag backfills ON ITS OWN (no open browser needed) WITHOUT
    blocking the request reactor. `ml_backfill_slice` is a non-blocking try-lock
    that honors the pause deadline (a live question is never delayed) and returns 0
    when paused, locked, or nothing is pending. Naps briefly between active slices,
    longer when idle (so a freshly-created tag starts within a few seconds). A pthread
    start routine must NEVER raise — swallow everything."""
    while True:
        var nap_us = 3000000  # ~3s idle poll for newly-pending work
        try:
            if ml_backfill_slice(_engine_url()) > 0:
                # Throttle between active slices per the user's priority — low leaves
                # long GPU-idle gaps (laptop stays usable), high runs near back-to-back.
                nap_us = nap_ms_for_priority(get_priority()) * 1000
        except:
            pass
        _usleep(nap_us)


def _progress_label(line: String) raises -> String:
    """Strip the progress sentinel off a captured stdout line, leaving the message
    the generated program passed to `progress(...)`."""
    return String(line.removeprefix(PROGRESS_SENTINEL))


def _unescape_nl(s: String) raises -> String:
    """Restore `\\n` (two chars) → a real newline. The LOCAL sentinel escapes newlines
    so each exchange stays one line; this undoes it for display. UTF-8 safe (splits the
    String, not its bytes)."""
    var parts = s.split("\\n")
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += "\n"
        out += String(parts[i])
    return out^


def _secs1(ms: Float64) -> String:
    """Milliseconds → seconds with one decimal: 38234.5 -> "38.2s"."""
    var tenths = Int(ms / 100.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10) + "s"


def _irate(n: Float64, ms: Float64) -> String:
    """Throughput `n` per second over `ms` milliseconds, integer: e.g. tokens/sec.
    Empty-time-safe (returns "0")."""
    if ms <= 0.0:
        return String("0")
    return String(Int(n * 1000.0 / ms + 0.5))


def _rate1(n: Float64, ms: Float64) -> String:
    """Throughput per second with one decimal — for the lower call rates (calls/s).
    """
    if ms <= 0.0:
        return String("0.0")
    var tenths = Int(n * 10000.0 / ms + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


def _dur(ms: Float64) -> String:
    """A single op's wall-clock: '210ms' under a second, else '1.2s'. For an op
    that ran ONCE, the duration is more telling than a per-second rate."""
    if ms < 1000.0:
        return String(Int(ms + 0.5)) + "ms"
    return _secs1(ms)


def _ms_since(t0: UInt) -> Float64:
    """Milliseconds elapsed since a perf_counter_ns() timestamp."""
    return Float64(perf_counter_ns() - t0) / 1.0e6


def _epoch_s() -> Int64:
    """Unix epoch seconds, right now — time(2) with a NULL arg. For stats timestamps
    (perf_counter_ns is monotonic, not wall-clock, so it can't date a record).
    """
    var null = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(0)
    )
    return external_call["time", Int64](null)


def _engine_url() -> String:
    """The on-device inference server's OpenAI-style root — where ML-tag
    classification (`ml_backfill_slice`) POSTs its yes/no batches. Same env the
    `millfolio` CLI reads, so the app and the CLI hit the one engine."""
    return String(getenv("MILLFOLIO_LOCAL_URL", "http://127.0.0.1:8000/v1"))


def _model_label() -> String:
    """The on-device model name shown in the UI's bottom bar + stamped on each stats
    record. MILLFOLIO_MODEL_LABEL (set by run-demo.sh from the engine's /v1/models)
    overrides; defaults to the Qwen the demo ships."""
    return String(getenv("MILLFOLIO_MODEL_LABEL", "Qwen2.5-3B-Instruct"))


# ── Model selection (on-device engine model) ────────────────────────────────
# The engine serves ONE model per process (chosen at launch); the selector below
# switches it by rewriting the engine config's `model` and restarting the engine
# LaunchAgent. The config is the single source of truth (the launch agent no longer
# hard-codes the model arg — see cli/Bootstrapper writeLaunchAgent).


def _hf_hub_dir() -> String:
    """The HuggingFace cache `hub/` dir (holds `models--<slug>` snapshots)."""
    var h = String(getenv("HF_HOME", "").strip())
    if h == "":
        h = getenv("HOME", ".") + "/Library/Application Support/Millfolio/hf"
    return h + "/hub"


def _engine_config_path() -> String:
    """The engine's config.json — the single source of truth for the served model.
    """
    var o = String(getenv("MILLFOLIO_CONFIG", "").strip())
    if o != "":
        return o^
    return getenv("HOME", ".") + "/.config/millfolio/config.json"


def _slug_to_id(slug: String) -> String:
    """`models--Qwen--Qwen2.5-3B-Instruct` -> `Qwen/Qwen2.5-3B-Instruct`
    (HF uses `--` between org and name; the name itself has no `--`)."""
    var s = slug
    if s.startswith("models--"):
        s = String(s[byte=8:])
    var i = s.find("--")
    if i == -1:
        return s^
    return String(s[byte=:i]) + "/" + String(s[byte = i + 2 :])


def _model_short(id: String) -> String:
    """The label after the last `/` (`Qwen/Qwen2.5-3B-Instruct` -> `Qwen2.5-3B-Instruct`).
    """
    var sl = id.find("/")
    if sl == -1:
        return id
    return String(id[byte = sl + 1 :])


def _id_to_slug(id: String) -> String:
    """`Qwen/Qwen2.5-3B-Instruct` -> `Qwen--Qwen2.5-3B-Instruct` (the HF cache dir
    name; inverse of `_slug_to_id`). Mirrors engine/src/download.mojo `slug()`.
    """
    var out = String("")
    var b = id.as_bytes()
    for i in range(len(b)):
        if b[i] == 47:  # '/'
            out += "--"
        else:
            out += chr(Int(b[i]))
    return out^


def _model_downloaded(id: String) -> Bool:
    """A checkpoint is fully materialized when its `refs/main` ref (the downloader's
    last write) is present under the HF hub cache."""
    return exists(_hf_hub_dir() + "/models--" + _id_to_slug(id) + "/refs/main")


def _catalog() -> List[List[String]]:
    """The supported chat models offered in the UI catalog: each `[id, label, GB]`.
    The FIRST entry is the default. Ids are PUBLIC HF repos the native downloader can
    fetch with no auth token (the gated google/* repos would 401); the engine loads
    every one (Qwen2.5 / Qwen3 / gemma-4 families). The demo is filtered to Qwen.
    """
    var out = List[List[String]]()
    out.append(
        [String("Qwen/Qwen2.5-3B-Instruct"), String("Qwen2.5-3B"), String("6")]
    )
    out.append(
        [
            String("mlx-community/gemma-4-e2b-it-bf16"),
            String("Gemma-4 E2B"),
            String("5"),
        ]
    )
    out.append(
        [
            String("mlx-community/gemma-4-12b-it-bf16"),
            String("Gemma-4 12B"),
            String("24"),
        ]
    )
    return out^


def _is_supported(id: String) -> Bool:
    """Is `id` one of the catalog's downloadable chat models?"""
    var cat = _catalog()
    for i in range(len(cat)):
        if cat[i][0] == id:
            return True
    return False


def _available_models_json() raises -> String:
    """JSON array [{"id","label","gb","downloaded"}] — the CATALOG of supported chat
    models each flagged downloaded/not (a `refs/main` ref present), PLUS any other
    fully-cached chat checkpoint the user fetched manually (offered as Use). The
    embedding model is excluded (it's a required dependency, not a chat choice). The
    public demo is Qwen-only."""
    var demo = _is_demo()
    var out = String("[")
    var n = 0
    var emitted = List[String]()
    var cat = _catalog()
    for i in range(len(cat)):
        var id = cat[i][0].copy()
        if demo and id.find("Qwen") == -1:
            continue
        var dl = _model_downloaded(id)
        if n > 0:
            out += ","
        out += (
            '{"id":'
            + json_escape(id)
            + ',"label":'
            + json_escape(cat[i][1])
            + ',"gb":'
            + cat[i][2]
            + ',"downloaded":'
            + ("true" if dl else "false")
            + "}"
        )
        emitted.append(id^)
        n += 1
    # Any OTHER fully-cached chat model not in the catalog → offer it as Use.
    var hub = _hf_hub_dir()
    if exists(hub):
        var entries = listdir(hub)
        for i in range(len(entries)):
            var name = String(entries[i])
            if not name.startswith("models--"):
                continue
            if not exists(hub + "/" + name + "/refs/main"):
                continue
            var id = _slug_to_id(name)
            if id.find("Embedding") != -1 or id.find("embedding") != -1:
                continue
            if not (
                id.find("Qwen2.5") != -1
                or id.find("Qwen3") != -1
                or id.find("gemma-4") != -1
                or id.find("Gemma-4") != -1
            ):
                continue
            if demo and id.find("Qwen") == -1:
                continue
            var seen = False
            for j in range(len(emitted)):
                if emitted[j] == id:
                    seen = True
                    break
            if seen:
                continue
            if n > 0:
                out += ","
            out += (
                '{"id":'
                + json_escape(id)
                + ',"label":'
                + json_escape(_model_short(id))
                + ',"gb":0,"downloaded":true}'
            )
            emitted.append(id^)
            n += 1
    out += "]"
    return out^


# ── weight downloads (native-Mojo downloader, run as a detached subprocess) ────
# Downloads moved out of the `mill` installer into this server: it runs the built
# `build/download` binary (MILLFOLIO_DOWNLOAD_BIN) — the SAME native-Mojo HF fetcher
# the CLI used to run — as a DETACHED process, tracking one download at a time via
# small state files in the config dir so a status endpoint can report progress.


def _download_bin() -> String:
    """Absolute path to the native-Mojo weights downloader (`build/download`), set by
    the CLI in the app-server LaunchAgent. Empty in dev / unmanaged runs → downloads
    are unavailable (the endpoints say so; the provisioner no-ops)."""
    return String(getenv("MILLFOLIO_DOWNLOAD_BIN", "").strip())


def _dl_state_path() -> String:
    return (
        _config_dir() + "/.model_download.state"
    )  # one word: running|done|error


def _dl_model_path() -> String:
    return _config_dir() + "/.model_download.model"  # the in-flight model id


def _dl_log_path() -> String:
    return _config_dir() + "/.model_download.log"  # captured stdout+stderr


def _write_small(path: String, text: String):
    """Best-effort single-file write (never raises)."""
    try:
        with open(path, "w") as f:
            f.write(text)
    except:
        pass


def _dl_progress() -> String:
    """The last non-empty line of the downloader's captured output — a human-readable
    progress detail (e.g. `wrote model-00001-of-00002.safetensors ( … bytes )`).
    """
    try:
        var s: String
        with open(_dl_log_path(), "r") as f:
            s = f.read()
        var lines = s.split("\n")
        var last = String("")
        for i in range(len(lines)):
            var ln = String(lines[i].strip())
            if ln != "":
                last = ln^
        return last^
    except:
        return String("")


def _dl_read_model() -> String:
    try:
        var m: String
        with open(_dl_model_path(), "r") as f:
            m = f.read()
        return String(m.strip())
    except:
        return String("")


def _catalog_gb(id: String) -> Int:
    """The catalog's approximate download size (whole GB) for `id`, or 0 if unknown
    (a manually-cached model not in the catalog). Used as the progress denominator."""
    var cat = _catalog()
    for i in range(len(cat)):
        if cat[i][0] == id:
            var out = 0
            var b = cat[i][2].as_bytes()
            for j in range(len(b)):
                var c = Int(b[j])
                if c >= 48 and c <= 57:
                    out = out * 10 + (c - 48)
            return out
    return 0


def _du_bytes(path: String) -> Int:
    """On-disk size of `path` in bytes via `du -sk` (KiB blocks → bytes) — the
    subprocess-to-temp-file pattern of `_gpu_util_pct`. Robust to the downloader's
    verbosity: we measure what has actually landed on disk. Returns -1 on miss."""
    if not exists(path):
        return 0
    var out_path = _config_dir() + "/.dl_du"
    var cmd = (
        String("cd / 2>/dev/null; du -sk '") + path + "' > '" + out_path + "'"
        " 2>/dev/null"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    try:
        var s: String
        with open(out_path, "r") as f:
            s = f.read()
        var kb = 0
        var indig = False
        var b = s.as_bytes()
        for i in range(len(b)):
            var c = Int(b[i])
            if c >= 48 and c <= 57:
                kb = kb * 10 + (c - 48)
                indig = True
            elif indig:
                break  # stop at the first non-digit (the tab before the path)
        return (kb * 1024) if indig else -1
    except:
        return -1


def _dl_progress_pct(id: String, done: Bool) raises -> Int:
    """Download progress 0–100 for `id`. `done` (refs/main present) short-circuits to
    100. Otherwise it's the on-disk size of the model's cache dir over the catalog's
    expected total. The catalog GB is the bf16 download size — a slight over-estimate
    of the final on-disk bytes — so the ratio can approach but should be clamped to
    <100 until genuinely done, avoiding a premature 100%. Returns -1 when unknown (no
    catalog size, or du failed) so the client falls back to the indeterminate spinner.
    """
    if done:
        return 100
    var gb = _catalog_gb(id)
    if gb <= 0:
        return -1
    var repo = _hf_hub_dir() + "/models--" + _id_to_slug(id)
    var on_disk = _du_bytes(repo)
    if on_disk < 0:
        return -1
    var total = gb * (1 << 30)  # GiB → bytes
    var pct = (on_disk * 100) // total
    if pct < 0:
        pct = 0
    if pct > 99:
        pct = 99  # never report 100 until refs/main lands (see docstring)
    return pct


def _download_status_json() raises -> String:
    """{"model","state","detail","progress","bytesDone","bytesTotal"} for the in-flight
    (or last) download. `state` is idle|running|done|error; `detail` is the latest
    downloader progress line. `progress` is 0–100 (integer; -1 when unknown → the
    client shows an indeterminate spinner). Self-heals to `done`/100 when `refs/main`
    appears (the fetch's final write)."""
    var model = _dl_read_model()
    var state = String("idle")
    var progress = -1
    var bytes_done = -1
    var bytes_total = -1
    if model != "":
        try:
            var s: String
            with open(_dl_state_path(), "r") as f:
                s = f.read()
            state = String(s.strip())
        except:
            state = String("running")
        var done = _model_downloaded(model)
        if done:
            state = String("done")
        # Only surface a live percentage while the fetch is active (or done).
        if state == "running" or state == "done":
            progress = _dl_progress_pct(model, done)
            var gb = _catalog_gb(model)
            if gb > 0:
                bytes_total = gb * (1 << 30)
                bytes_done = bytes_total if done else _du_bytes(
                    _hf_hub_dir() + "/models--" + _id_to_slug(model)
                )
    return (
        '{"model":'
        + json_escape(model)
        + ',"state":'
        + json_escape(state)
        + ',"detail":'
        + json_escape(_dl_progress())
        + ',"progress":'
        + String(progress)
        + ',"bytesDone":'
        + String(bytes_done)
        + ',"bytesTotal":'
        + String(bytes_total)
        + "}"
    )


def _download_running() raises -> Bool:
    """True iff a download is genuinely in flight (state==running AND not yet on
    disk) — the guard against starting a second concurrent download."""
    var model = _dl_read_model()
    if model == "" or _model_downloaded(model):
        return False
    try:
        var s: String
        with open(_dl_state_path(), "r") as f:
            s = f.read()
        return String(s.strip()) == "running"
    except:
        return False


def _dl_core_cmd(id: String) -> String:
    """The shell command that runs the downloader for `id`, appending output to the
    capture log. Runs from the runner dir (two levels up from build/download) with
    CONDA_PREFIX/MODULAR_HOME cleared — matching the CLI's runtimeEnv so flare loads
    its own libflare_tls.so next to the binary, not from the toolchain prefix. HF_HOME
    + SSL_CERT_FILE are inherited from this server's environment."""
    var bin = _download_bin()
    return (
        "d=\"$(dirname '"
        + bin
        + '\')/.."; cd "$d" && env -u CONDA_PREFIX -u MODULAR_HOME \''
        + bin
        + "' '"
        + id
        + "' >> '"
        + _dl_log_path()
        + "' 2>&1"
    )


def _begin_download_state(id: String):
    """Mark `id` as the in-flight download (running) and truncate the capture log.
    """
    _write_small(_dl_model_path(), id)
    _write_small(_dl_state_path(), "running")
    _write_small(_dl_log_path(), "")


def _start_download_detached(id: String) -> Bool:
    """Start a DETACHED download of `id` (returns immediately). Wraps the core command
    so the shell flips the state file to done/error on completion; backgrounded +
    </dev/null so it outlives the request and never becomes our zombie. False when the
    downloader isn't configured."""
    if _download_bin() == "":
        return False
    _begin_download_state(id)
    var state = _dl_state_path()
    var cmd = (
        "( "
        + _dl_core_cmd(id)
        + " && printf done > '"
        + state
        + "' || printf error > '"
        + state
        + "' ) </dev/null &"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    return True


def _provision_fetch(id: String) -> Bool:
    """BLOCKING fetch of `id` to completion (called on the provisioner thread, so it
    doesn't block the reactor). No-op True when already present; False when the
    downloader isn't available. Updates the SAME state files as the endpoint, so the
    catalog reflects provisioning progress + the concurrency guard holds."""
    if _model_downloaded(id):
        return True
    if _download_bin() == "":
        return False
    _begin_download_state(id)
    var cc = _cstr(_dl_core_cmd(id))
    _ = external_call["system", Int32](cc)  # waits (no trailing &)
    cc.free()
    var ok = _model_downloaded(id)  # refs/main appears only on full success
    _write_small(_dl_state_path(), "done" if ok else "error")
    return ok


# ── sample vault (first-run onboarding) ────────────────────────────────────────
# A new user with an empty vault can "try it with sample data": we fetch a small
# hosted zip (MILLFOLIO_DEMO_URL), unpack it into `<data>/demo-vault/`, and index
# it via the engine run-script — the SAME `millfolio index` path `mill index` uses,
# so the docs + transactions become queryable. Runs as a DETACHED shell job (like a
# weight download), tracking state in a small file the status endpoint reports.


def _demo_url() -> String:
    """The hosted sample-vault zip. Overridable via MILLFOLIO_DEMO_URL (e.g. a local
    file:// or a staging host); defaults to the public millfolio.app asset."""
    var u = String(getenv("MILLFOLIO_DEMO_URL", "").strip())
    if u != "":
        return u
    return String("https://millfolio.app/demo-vault.zip")


def _demo_dir() -> String:
    """Where the unpacked sample vault lands — `<data>/demo-vault/` (the zip unpacks
    a `demo-vault/` folder into the data dir)."""
    return _config_dir() + "/demo-vault"


def _demo_zip_path() -> String:
    return _config_dir() + "/.demo-vault.zip"


def _demo_state_path() -> String:
    return _config_dir() + "/.demo.state"  # downloading|indexing|done|error


def _demo_log_path() -> String:
    return _config_dir() + "/.demo.log"  # captured curl/unzip/index output


def _demo_present() -> Bool:
    """True once the sample vault has been unpacked (the folder exists)."""
    return isdir(_demo_dir())


def _demo_read_state() -> String:
    try:
        var s: String
        with open(_demo_state_path(), "r") as f:
            s = f.read()
        return String(s.strip())
    except:
        return String("idle")


def _demo_running() -> Bool:
    """True while the import is genuinely in flight (downloading or indexing).
    """
    var st = _demo_read_state()
    return st == "downloading" or st == "indexing"


def _demo_progress() -> String:
    """The last non-empty captured line — a human-readable progress detail."""
    try:
        var s: String
        with open(_demo_log_path(), "r") as f:
            s = f.read()
        var lines = s.split("\n")
        var last = String("")
        for i in range(len(lines)):
            var ln = String(lines[i].strip())
            if ln != "":
                last = ln^
        return last^
    except:
        return String("")


def _demo_status_json() raises -> String:
    """{"state","detail","present"} for the sample-vault import. `state` is
    idle|downloading|indexing|done|error; `present` is whether the folder exists.
    """
    var state = _demo_read_state()
    return (
        '{"state":'
        + json_escape(state)
        + ',"detail":'
        + json_escape(_demo_progress())
        + ',"present":'
        + ("true" if _demo_present() else "false")
        + "}"
    )


def _start_demo_detached() -> Bool:
    """Start the DETACHED download+unpack+index of the sample vault (returns
    immediately). A single &&-chain flips the state file through
    downloading→indexing→done (or error on any failure); output is captured to the
    log. `</dev/null &` so it outlives the request. False when the run-script isn't
    configured (indexing would be impossible)."""
    var run_script = String(getenv("MILLFOLIO_RUN_SCRIPT", "").strip())
    if run_script == "":
        return False
    var data = _config_dir()
    var dir = _demo_dir()
    var zip = _demo_zip_path()
    var state = _demo_state_path()
    var log = _demo_log_path()
    var url = _demo_url()
    # printf/echo always succeed, so the whole pipeline can chain on && and any real
    # failure short-circuits to the trailing `|| printf error`.
    var cmd = (
        "( printf downloading > '"
        + state
        + "' && echo 'Downloading sample data…' > '"
        + log
        + "'"
        + " && curl -fsSL '"
        + url
        + "' -o '"
        + zip
        + "' 2>> '"
        + log
        + "'"
        + " && printf indexing > '"
        + state
        + "' && echo 'Unpacking…' >> '"
        + log
        + "'"
        + " && rm -rf '"
        + dir
        + "' && unzip -o '"
        + zip
        + "' -d '"
        + data
        + "' >> '"
        + log
        + "' 2>&1"
        + " && echo 'Indexing sample data (loads the embedding model)…' >> '"
        + log
        + "'"
        + " && /bin/bash '"
        + run_script
        + "' index '"
        + dir
        + "' --force >> '"
        + log
        + "' 2>&1"
        + " && printf done > '"
        + state
        + "' || printf error > '"
        + state
        + "' ) </dev/null &"
    )
    _write_small(state, "downloading")
    _write_small(log, "")
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    return True


# ── general folder/file indexing (Vault/Files) ────────────────────────────────
# The SAME detached-job + state/log-file pattern as the sample-vault import above,
# generalised to any local path, plus a small tracked-folders registry so a re-index
# can pick up new files. See `handle_index` for the append-not-clobber rationale.


def _index_state_path() -> String:
    return _config_dir() + "/.index.state"  # idle|indexing|done|error


def _index_log_path() -> String:
    return _config_dir() + "/.index.log"  # captured indexer output


def _tracked_paths_path() -> String:
    return _config_dir() + "/indexed-paths.json"  # the tracked-folders registry


def _index_read_state() -> String:
    try:
        var s: String
        with open(_index_state_path(), "r") as f:
            s = f.read()
        return String(s.strip())
    except:
        return String("idle")


def _index_running() -> Bool:
    """True while an index job is genuinely in flight."""
    return _index_read_state() == "indexing"


def _index_progress() -> String:
    """The last non-empty captured line — a human-readable progress detail."""
    try:
        var s: String
        with open(_index_log_path(), "r") as f:
            s = f.read()
        var lines = s.split("\n")
        var last = String("")
        for i in range(len(lines)):
            var ln = String(lines[i].strip())
            if ln != "":
                last = ln^
        return last^
    except:
        return String("")


def _index_status_json() raises -> String:
    """{"state","detail"} for the folder-index job — same shape as the demo status.
    `state` is idle|indexing|done|error."""
    return (
        '{"state":'
        + json_escape(_index_read_state())
        + ',"detail":'
        + json_escape(_index_progress())
        + "}"
    )


@fieldwise_init
struct _Tracked(Copyable, Movable):
    """The tracked-folders registry, split into parallel lists: `paths[i]` was last
    indexed at epoch-seconds `epochs[i]` (stored as a string)."""

    var paths: List[String]
    var epochs: List[String]


def _read_tracked() raises -> _Tracked:
    """Parse indexed-paths.json → parallel (path, lastIndexed) lists. Empty when the
    file is missing/blank/corrupt (best-effort — a bad registry never wedges the UI).
    """
    var paths = List[String]()
    var epochs = List[String]()
    if not exists(_tracked_paths_path()):
        return _Tracked(paths^, epochs^)
    var text: String
    with open(_tracked_paths_path(), "r") as f:
        text = f.read()
    if String(text.strip()) == "":
        return _Tracked(paths^, epochs^)
    try:
        var j = loads(text)
        var arr = j["folders"]
        for i in range(arr.array_count()):
            paths.append(String(arr[i]["path"].string_value()))
            try:
                epochs.append(String(arr[i]["lastIndexed"].string_value()))
            except:
                epochs.append(String(""))
    except:
        pass
    return _Tracked(paths^, epochs^)


def _read_tracked_paths() raises -> List[String]:
    """Just the tracked folder paths (convenience for the index/reindex handlers)."""
    var t = _read_tracked()
    return t.paths.copy()


def _write_tracked(paths: List[String], epochs: List[String]) raises:
    """Persist the registry as indexed-paths.json (`{"folders":[{path,lastIndexed}]}`).
    `epochs[i]` is epoch-seconds-as-string (or "" if unknown)."""
    var out = String('{"folders":[')
    for i in range(len(paths)):
        if i > 0:
            out += ","
        var ep = epochs[i] if i < len(epochs) else String("")
        out += (
            '{"path":'
            + json_escape(paths[i])
            + ',"lastIndexed":'
            + json_escape(ep)
            + "}"
        )
    out += "]}"
    _write_small(_tracked_paths_path(), out)


def _tracked_folders_json() raises -> String:
    """GET /api/index/folders body: {"folders":[{"path","lastIndexed"}]}. Re-serialised
    from the parsed registry so a hand-mangled file still returns valid JSON."""
    var t = _read_tracked()
    var out = String('{"folders":[')
    for i in range(len(t.paths)):
        if i > 0:
            out += ","
        out += (
            '{"path":'
            + json_escape(t.paths[i])
            + ',"lastIndexed":'
            + json_escape(t.epochs[i])
            + "}"
        )
    out += "]}"
    return out^


def _sh_squote(s: String) raises -> String:
    """Single-quote `s` for /bin/sh, escaping embedded single quotes as '\\''. Makes a
    user-supplied path (spaces, `$`, …) a safe single shell word."""
    var parts = s.split("'")
    var out = String("'")
    for i in range(len(parts)):
        if i > 0:
            out += "'\\''"
        out += String(parts[i])
    out += "'"
    return out^


def _start_index_detached(paths: List[String]) -> Bool:
    """Start the DETACHED `millfolio index <paths…>` over the whole tracked union (no
    --force → incremental: unchanged files are skipped), flipping the state file
    indexing→done (error on any failure); output captured to the log. Stamps every
    path in `paths` as the tracked set with `lastIndexed = now` (they're all indexed
    in this run). False when the run-script isn't configured or no paths were given.
    """
    var run_script = String(getenv("MILLFOLIO_RUN_SCRIPT", "").strip())
    if run_script == "" or len(paths) == 0:
        return False
    var state = _index_state_path()
    var log = _index_log_path()
    var args = String("")
    try:
        for i in range(len(paths)):
            args += " " + _sh_squote(paths[i])
    except:
        return False
    # printf/echo always succeed, so the chain flips indexing→done and any real
    # failure short-circuits to the trailing `|| printf error`.
    var cmd = (
        "( printf indexing > '"
        + state
        + "' && echo 'Indexing…' > '"
        + log
        + "'"
        + " && /bin/bash '"
        + run_script
        + "' index"
        + args
        + " >> '"
        + log
        + "' 2>&1"
        + " && printf done > '"
        + state
        + "' || printf error > '"
        + state
        + "' ) </dev/null &"
    )
    # Record the tracked set (all indexed now) BEFORE launching, so a poll of
    # /api/index/folders right after start already reflects the new path.
    try:
        var now = String(_epoch_s())
        var epochs = List[String]()
        for _ in range(len(paths)):
            epochs.append(now)
        _write_tracked(paths, epochs)
    except:
        pass
    _write_small(state, "indexing")
    _write_small(log, "")
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()
    return True


def _autofetch_default() -> Bool:
    """Whether to auto-fetch the DEFAULT chat model on startup. On by default; set
    MILLFOLIO_AUTOFETCH_DEFAULT_MODEL=0 to "start empty" and let the user pick from
    the catalog. (The embedding model is always fetched — it's a hard dependency.)
    """
    return (
        String(getenv("MILLFOLIO_AUTOFETCH_DEFAULT_MODEL", "1").strip()) != "0"
    )


def _provision_worker(arg: _OpaquePtr) -> _OpaquePtr:
    """Detached startup thread: ensure the REQUIRED embedding model is present (the
    engine 503s /v1/embeddings without it → indexing + search break), then — unless
    disabled — a DEFAULT chat model so the app works out of the box after a weights-
    free install. Both are no-ops when already cached. Once a servable model is on
    disk but the engine isn't serving (it exited earlier when weights were missing),
    kickstart it. This routine is non-raising by signature (every helper it calls is),
    so a pthread start routine can never raise out of it."""
    if _download_bin() == "":
        return arg  # no downloader configured → nothing to provision
    # 1. Embedding model — a hard dependency, always fetched (not in the catalog).
    _ = _provision_fetch(String(EMBED_MODEL))
    # 2. Default chat model — toggleable (start-empty deploys flip it off).
    if _autofetch_default() and not _model_downloaded(
        String(DEFAULT_CHAT_MODEL)
    ):
        _ = _provision_fetch(String(DEFAULT_CHAT_MODEL))
    # 3. Make the engine serve a downloaded model. If its configured model isn't on
    #    disk but the default now is, repoint config at the default; then, if a
    #    servable model is present but the engine isn't serving, kickstart it.
    var want = _current_model_id()
    if not _model_downloaded(want) and _model_downloaded(
        String(DEFAULT_CHAT_MODEL)
    ):
        _ = _config_set_model(String(DEFAULT_CHAT_MODEL))
        want = String(DEFAULT_CHAT_MODEL)
    if _model_downloaded(want) and _engine_loaded_model() == "":
        _restart_engine()
    return arg


def _current_model_id() -> String:
    """The engine's selected model id, read from its config.json (falls back to the
    label env / the Qwen default)."""
    try:
        var text: String
        with open(_engine_config_path(), "r") as f:
            text = f.read()
        var m = String(loads(text)["model"].string_value())
        if m != "":
            return m^
    except:
        pass
    return String(getenv("MILLFOLIO_MODEL_LABEL", "Qwen/Qwen2.5-3B-Instruct"))


def _config_set_model(id: String) -> Bool:
    """Rewrite the engine config's `model` field to `id`, preserving port/q4/
    kv_budget_mb. Returns True on success."""
    var path = _engine_config_path()
    var port = Int64(8000)
    var q4 = False
    var kv = Int64(8192)
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var j = loads(text)
        try:
            port = j["port"].int_value()
        except:
            pass
        try:
            q4 = j["q4"].bool_value()
        except:
            pass
        try:
            kv = j["kv_budget_mb"].int_value()
        except:
            pass
    except:
        pass
    if String(getenv("MILLFOLIO_CONFIG", "").strip()) == "":
        try:
            makedirs(getenv("HOME", ".") + "/.config/millfolio", exist_ok=True)
        except:
            pass
    var body = (
        '{\n  "port": '
        + String(port)
        + ',\n  "model": '
        + json_escape(id)
        + ',\n  "q4": '
        + ("true" if q4 else "false")
        + ',\n  "kv_budget_mb": '
        + String(kv)
        + "\n}\n"
    )
    try:
        with open(path, "w") as f:
            f.write(body)
        return True
    except:
        return False


def _restart_engine():
    """Kick the engine LaunchAgent (me.millfolio.server) so it reloads with the
    newly-selected model. `-k` stops the running instance first."""
    var uid = Int(external_call["getuid", UInt32]())
    var cmd = (
        "launchctl kickstart -k gui/"
        + String(uid)
        + "/me.millfolio.server >/dev/null 2>&1"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](cc)
    cc.free()


def _engine_loaded_model() -> String:
    """The chat model the engine is ACTUALLY serving right now, from its
    /v1/models — the readiness signal the UI polls during a switch. Empty when the
    engine is down (e.g. mid-restart) or unreachable; best-effort, fails fast.
    """
    try:
        var req = Request(method="GET", url=_engine_url() + "/models")
        var client = HttpClient()
        var v = client.send(req).json()
        var arr = v["data"]
        for i in range(arr.array_count()):
            var mid = String(arr[i]["id"].string_value())
            if mid.find("Embedding") == -1 and mid.find("embedding") == -1:
                return mid^  # the chat model (skip the embeddings model)
    except:
        pass
    return String("")


def _app_version() -> String:
    """The deployed build label (matches the UI's bottom-bar stamp: '<sha> · <date>').
    Stamped on each stats record so the Stats page can average per deployed version.
    MILLFOLIO_VERSION is set by run-demo.sh from the deploy stamp; 'dev' otherwise.
    """
    return String(getenv("MILLFOLIO_VERSION", "dev"))


def _stats_path() -> String:
    """Where per-question usage records accumulate (JSONL). MILLFOLIO_STATS_FILE
    overrides; defaults under the config dir (which `cp -R` deploys never delete).
    """
    return String(
        getenv("MILLFOLIO_STATS_FILE", _config_dir() + "/stats.jsonl")
    )


def _append_stats(
    epoch: Int64,
    question: String,
    label: String,
    version: String,
    ok: Bool,
    total_ms: Float64,
    pf_tok: Int,
    gen_tok: Int,
    pf_ms: Float64,
    dec_ms: Float64,
    names: List[String],
    counts: List[Int],
    ms: List[Float64],
):
    """Append ONE self-contained JSON object (a usage record) to the stats file.
    JSONL — one object per line — so /api/stats can return the file verbatim and the
    browser does the averaging (the Mojo json lib is avoided on this path). Best-effort:
    a write failure is logged, never propagated into the chat reply."""
    var api = String("[")
    for i in range(len(names)):
        if i > 0:
            api += ","
        api += (
            "["
            + json_escape(names[i])
            + ","
            + String(counts[i])
            + ","
            + String(Int(ms[i] + 0.5))
            + "]"
        )
    api += "]"
    var line = (
        '{"ts":'
        + String(epoch)
        + ',"q":'
        + json_escape(question)
        + ',"model":'
        + json_escape(label)
        + ',"version":'
        + json_escape(version)
        + ',"ok":'
        + ("true" if ok else "false")
        + ',"total_ms":'
        + String(Int(total_ms + 0.5))
        + ',"prefill_tok":'
        + String(pf_tok)
        + ',"gen_tok":'
        + String(gen_tok)
        + ',"prefill_ms":'
        + String(Int(pf_ms + 0.5))
        + ',"decode_ms":'
        + String(Int(dec_ms + 0.5))
        + ',"api":'
        + api
        + "}\n"
    )
    try:
        with open(_stats_path(), "a") as f:
            f.write(line)
        _chmod(
            _stats_path(), 0o600
        )  # owner-only: records the full question text
    except:
        log("[stats] append failed (non-fatal)")


def _asks_path() -> String:
    """Where the FULL per-ask history accumulates (JSONL): the question, the
    GENERATED program, and the answer. Durable + on-device under the config dir
    (which `cp -R` deploys never delete) — survives a browser-data clear, unlike
    the UI's localStorage. MILLFOLIO_ASKS_FILE overrides."""
    return String(getenv("MILLFOLIO_ASKS_FILE", _config_dir() + "/asks.jsonl"))


def _append_ask(
    epoch: Int64,
    question: String,
    code: String,
    answer: String,
    source: String,
    model: String,
    ok: Bool,
):
    """Append ONE self-contained JSON record — {ts, q, code, answer, source, model,
    ok} — to the per-ask history file (JSONL). This is the durable backend store
    behind the chat history panel: every ask is kept forever with the program that
    was generated and the answer it produced. Best-effort — a write failure is
    logged, never propagated into the chat reply."""
    var line = ask_record_line(epoch, question, code, answer, source, model, ok)
    try:
        with open(_asks_path(), "a") as f:
            f.write(line + "\n")  # JSONL — one record per line
        _chmod(_asks_path(), 0o600)  # owner-only: holds questions + answers
    except:
        log("[asks] append failed (non-fatal)")


def _bump(
    mut names: List[String],
    mut counts: List[Int],
    mut ms: List[Float64],
    name: String,
    n: Int,
    dt: Float64,
):
    """Accumulate `n` calls (+ `dt` ms) under `name` in the parallel api-stat lists
    — find-or-append, so any tool/codegen name aggregates without a fixed schema.
    """
    for i in range(len(names)):
        if names[i] == name:
            counts[i] += n
            ms[i] += dt
            return
    names.append(name)
    counts.append(n)
    ms.append(dt)


def _live_stats(
    names: List[String], counts: List[Int], pf_tok: Int, gen_tok: Int
) -> String:
    """Running per-api call counts + model token tallies appended to the live
    working line — only the categories seen so far (empty stays clean)."""
    var s = String("")
    for i in range(len(names)):
        # Single op → just the name; repeated → ×count.
        if counts[i] == 1:
            s += " · " + names[i]
        else:
            s += " · " + names[i] + " ×" + String(counts[i])
    if pf_tok > 0:
        s += " · prefill " + String(pf_tok) + " tok"
    if gen_tok > 0:
        s += " · gen " + String(gen_tok) + " tok"
    return s^


# ── serial run-queue ─────────────────────────────────────────────────────────
# The FIFO ticket queue (one sandboxed run at a time across workers, with each
# waiter's live position) lives in runqueue.mojo and is unit-tested by
# test/runqueue_test.mojo. A run is ALSO time-bounded here (the child is killed past
# _RUN_MAX_ITERS) so one slow/stuck program can't stall the whole queue.
comptime _SIGKILL: Int = 9
comptime _RUN_MAX_ITERS: Int = 1000  # ~120s at 120ms/poll — kill a run past this


struct WsSink(DeltaSink, Movable):
    """Live codegen feedback: as the frontier model streams the program, update the ONE
    "codegen" status line in place with the growing size, so the user sees the model
    actively producing output (not just elapsed time). Coalesced (~200 chars) so it
    doesn't flood the WS. Holds the connection by pointer — valid for the duration of
    the synchronous `vault_codegen_stream` call within `on_connect`."""

    var conn_addr: Int  # address of the on_connect `conn` (alive for the call)
    var chars: Int
    var last: Int

    def __init__(out self, conn_addr: Int):
        self.conn_addr = conn_addr
        self.chars = 0
        self.last = 0

    def on_delta(mut self, text: String) raises:
        self.chars += text.byte_length()
        if self.chars - self.last >= 200:
            self.last = self.chars
            var conn = UnsafePointer[WsConnection, MutUntrackedOrigin](
                unsafe_from_address=self.conn_addr
            )
            conn[].send_text(
                status(
                    "codegen",
                    "Writing the program… (" + String(self.chars) + " chars)",
                    "running",
                )
            )


def on_connect(mut conn: WsConnection) raises:
    """Streaming chat over the SAME :10000 listener — flare upgrades the WebSocket
    request; every other request stays on the unary HTTP path (the `Api` handler).
    One WS connection = one chat session: stream a status/debug event per stage and
    gate the sandbox run on the user's approval (the blocking `recv()` IS the pause).

    flare's WS handler is THIN (non-capturing), so it builds the orchestrator per
    connection — fine for a local single-user server. Events are ServerEvent JSON,
    one per text frame (see ../../protocol/events.ts / events.mojo)."""
    # Same-origin gate. Browsers don't apply the same-origin policy to ws://
    # connects, so without this any website the user visits could open this
    # socket, ask, auto-approve, and read the streamed vault answer. Empty
    # Origin (a non-browser client) is allowed; a non-loopback Origin is not.
    # Skipped in demo mode (served under a real hostname; synthetic data behind
    # the Turnstile token gate below — same rationale as Api.serve).
    var _ws_origin = String(conn.origin)
    if (
        not _is_demo()
        and _ws_origin != ""
        and not _host_allowed(_extract_host(_ws_origin))
    ):
        conn.send_text(error_event("cross-origin websocket rejected"))
        conn.close(WsCloseCode.NORMAL)
        return
    var frame = conn.recv()
    if frame.opcode == WsOpcode.CLOSE:
        return
    var question = field(frame.text_payload(), "text")
    if question == "":
        conn.send_text(error_event("empty or malformed ask"))
        conn.close(WsCloseCode.NORMAL)
        return
    # Demo bot gate: require a valid demo-access token (minted after a Turnstile solve)
    # on every chat frame. Server-enforced, so a bot can't skip the client widget. No-op
    # when the gate is off (real product / local dev / no secret configured).
    if _turnstile_enabled() and not _demo_token_valid(
        field(frame.text_payload(), "demo_token")
    ):
        conn.send_text(
            error_event("please complete the human check to use the demo")
        )
        conn.close(WsCloseCode.NORMAL)
        return
    var ticket = (
        -1
    )  # our run-queue ticket; >= 0 once we've entered (see runqueue.mojo)
    try:
        var cfg = load_config()
        var vault_dir = resolve_vault_dir()
        var orch = build_vault_orchestrator(cfg, vault_dir)

        # Run-stats accumulator — api call counts (codegen-phase + the vault tools the
        # generated program calls) and the model's prefill/gen tokens. Declared here so
        # the codegen/fix calls below feed the SAME tallies the run loop extends.
        var api_names = List[String]()
        var api_count = List[Int]()
        var api_ms = List[Float64]()
        var pf_tok = 0
        var gen_tok = 0
        var pf_ms = 0.0
        var dec_ms = 0.0

        # Wall-clock for the stats record: the WORK time (manifest+codegen, then
        # compile+run), deliberately EXCLUDING the human approval pause + queue wait.
        var t_total0 = perf_counter_ns()
        var pre_ms: Float64
        conn.send_text(status("manifest", "Aliasing vault manifest", "running"))
        var _t = perf_counter_ns()
        var manifest = orch.vault_manifest(vault_dir)
        _bump(api_names, api_count, api_ms, "alias", 1, _ms_since(_t))
        # The frontier-safe view also carries the category tag NAMES + scope notes
        # (so the model filters `.tags`); never the keyword RULES (real merchant
        # strings → on-device). DISPLAY-ONLY truncation so this dropdown stays
        # readable as the vault grows — show the first few of each group + the total.
        # The FULL manifest + tag list still go to the model (codegen uses `manifest`
        # / _tags_context, untouched); this only shapes the debug body.
        var _head = 3
        var _dbg = String("")
        # Manifest: keep the header lines (vault:/count), cap the `file_` lines.
        var _files = List[String]()
        var _mlines = manifest.split("\n")
        for _i in range(len(_mlines)):
            var _ln = String(_mlines[_i])
            if String(_ln.strip()).startswith("file_"):
                _files.append(_ln)
            elif String(_ln.strip()).byte_length() > 0:
                if _dbg.byte_length() > 0:
                    _dbg += "\n"
                _dbg += _ln
        for _i in range(len(_files)):
            if _i >= _head:
                break
            if _dbg.byte_length() > 0:
                _dbg += "\n"
            _dbg += _files[_i]
        if len(_files) > _head:
            _dbg += (
                "\n  … and "
                + String(len(_files) - _head)
                + " more files ("
                + String(len(_files))
                + " total)"
            )
        # Category tags (name + scope note), capped the same way.
        var _avail = effective_tags()
        var _adesc = effective_tag_descriptions()
        if len(_avail) > 0:
            _dbg += (
                "\n\nCategory tags also sent (name + scope note; the model"
                " filters .tags on these):"
            )
            for _i in range(len(_avail)):
                if _i >= _head:
                    break
                _dbg += "\n- " + _avail[_i]
                if _i < len(_adesc) and _adesc[_i].byte_length() > 0:
                    _dbg += " — " + _adesc[_i]
            if len(_avail) > _head:
                _dbg += (
                    "\n  … and "
                    + String(len(_avail) - _head)
                    + " more tags ("
                    + String(len(_avail))
                    + " total)"
                )
        conn.send_text(
            debug_event(
                "manifest",
                "Frontier-safe view — aliases + category tag names",
                _dbg,
                "text",
            )
        )
        conn.send_text(status("manifest", "Aliasing vault manifest", "done"))

        conn.send_text(status("codegen", "Writing the program", "running"))
        _t = perf_counter_ns()
        var code: String
        if getenv("MILLFOLIO_STREAM_CODEGEN", "") != "":
            # Stream the program — update the "codegen" line live with its size.
            var sink = WsSink(Int(UnsafePointer(to=conn)))
            code = orch.vault_codegen_stream(question, manifest, sink)
        else:
            code = orch.vault_codegen(question, manifest)
        _bump(api_names, api_count, api_ms, "codegen", 1, _ms_since(_t))
        conn.send_text(
            debug_event("codegen", "Generated program", code, "mojo")
        )
        conn.send_text(status("codegen", "Writing the program", "done"))
        # Surface which category tags the program filtered on (so the user knows
        # the answer came from a tag, not a guess) — the available tag NAMES that
        # appear as a quoted literal in the program (`"phone" in t.tags`).
        var used = _tags_in_program(code)
        if used.byte_length() > 0:
            conn.send_text(tags_event(used))
        # If the model proposed a NEW reusable tag for a category that isn't one
        # yet, surface it so the user can save it (next time = a fast `.tags`
        # filter, not an inline classify). A comment in the program; never runs.
        var prop = _tag_proposal_in_program(code)
        if len(prop) == 3:
            conn.send_text(tag_proposal_event(prop[0], prop[1], prop[2]))
        pre_ms = _ms_since(
            t_total0
        )  # manifest + codegen, before the approval pause

        conn.send_text(
            status(
                "run",
                "Run the generated program over your vault?",
                "awaiting-approval",
            )
        )
        conn.send_text(
            approval("run", "Run the generated program over your vault?", code)
        )
        var decision = conn.recv()
        if (
            decision.opcode == WsOpcode.CLOSE
            or field(decision.text_payload(), "type") != "approve"
        ):
            conn.send_text(status("run", "Run rejected", "error"))
            conn.send_text(
                message(
                    "Okay — I won't run that. Tell me how you'd like to"
                    " adjust it."
                )
            )
            conn.close(WsCloseCode.NORMAL)
            return

        # Enter the serial run-queue — AFTER approval. With multiple workers several
        # visitors reach here at once; only ONE runs at a time (shared scratch path +
        # heavy build + on-device inference). Take a FIFO ticket and wait our turn,
        # streaming our live position so the wait isn't a blind spinner.
        ticket = runq_take()
        var st = runq_peek()
        # Always surface the queue position — even "1 of 1" for a solo run — so the
        # serial run-queue is visible, and update it live while we wait our turn.
        var waited = 0
        while True:
            var ahead = ticket - st[0]  # people in front of us
            if ahead <= 0:
                conn.send_text(
                    status("queue", "You're next — running now", "done")
                )
                break
            waited += 1
            if (
                waited > 600
            ):  # ~300s — assume the queue stalled; take our turn anyway
                conn.send_text(status("queue", "Starting now", "done"))
                break
            conn.send_text(
                status(
                    "queue",
                    "There are " + String(ahead) + " ahead of you",
                    "running",
                )
            )
            _usleep(500_000)  # re-check twice a second
            st = runq_peek()

        # Approved — surface the two real phases SEPARATELY so the wait isn't one
        # opaque "working": first compile the generated Mojo, then run it over the
        # vault (the read + ask_local loop — the long part). The run is now spawned
        # NON-BLOCKING and we poll its captured stdout, streaming each `progress(…)`
        # line the generated program emits as a live "execute" status update (same
        # stepId, so the UI updates ONE line in place) instead of a frozen spinner.
        conn.send_text(status("run", "Approved — running", "done"))
        var t_run0 = (
            perf_counter_ns()
        )  # compile + run wall-clock (post-approval/queue)
        conn.send_text(
            status("compile", "Compiling the generated program", "running")
        )
        _t = perf_counter_ns()
        var fixes = orch.vault_build(code)
        _bump(api_names, api_count, api_ms, "compile", 1, _ms_since(_t))
        if fixes > 0:
            _bump(api_names, api_count, api_ms, "fix", fixes, 0.0)
        conn.send_text(
            status("compile", "Compiling the generated program", "done")
        )
        conn.send_text(
            status("execute", "Running it locally over your vault…", "running")
        )
        var h = orch.vault_run_start(vault_dir)
        log("[run] poll start: pid=" + String(Int(h.pid)))
        var cur_label = String("Running it locally over your vault…")
        var src_file = String(
            ""
        )  # first document a tool read — surfaced as the source
        var src_alias = String("")  # …its alias, for the /api/doc?alias= link
        var result_spec = String(
            ""
        )  # the generated program's declarative RESULT SPEC (v:1 JSON), if any
        var running = True
        var iters = 0
        var timed_out = False
        while running:
            # Reap FIRST, then poll — so the final poll (once the child has exited)
            # still drains every progress/stat line written just before it died.
            var reap = orch.vault_run_reap(h)
            running = reap == -1  # -1 = still running
            var lines = orch.vault_run_poll(h)
            if (
                iters % 16 == 0
            ):  # ~every 2s: prove the loop's alive + where it's stuck
                log(
                    "[run] poll iter="
                    + String(iters)
                    + " reap="
                    + String(reap)
                    + " captured="
                    + String(h.cursor)
                    + "B"
                )
            var dirty = False
            for i in range(len(lines)):
                var ln = lines[i].copy()
                if ln.startswith(PROGRESS_SENTINEL):
                    cur_label = _progress_label(ln)
                    dirty = True
                elif ln.startswith(STAT_SENTINEL):
                    var parts = String(ln.removeprefix(STAT_SENTINEL)).split(
                        "\t"
                    )
                    if len(parts) >= 5 and String(parts[0]) == "model":
                        # "model\t<pf_tok>\t<gen_tok>\t<pf_ms>\t<dec_ms>" — engine prefill/gen.
                        pf_tok += Int(atof(String(parts[1])))
                        gen_tok += Int(atof(String(parts[2])))
                        pf_ms += atof(String(parts[3]))
                        dec_ms += atof(String(parts[4]))
                        dirty = True
                    elif len(parts) >= 3 and String(parts[0]) == "source":
                        # "source\t<alias>\t<filename>" — the first document a tool read.
                        if src_alias == "":
                            src_alias = String(parts[1])
                            src_file = String(parts[2])
                    elif len(parts) == 2:
                        # "<tool>\t<ms>" — one vault-tool API call + its duration.
                        _bump(
                            api_names,
                            api_count,
                            api_ms,
                            String(parts[0]),
                            1,
                            atof(String(parts[1])),
                        )
                        dirty = True
                elif ln.startswith(LOCAL_SENTINEL):
                    # An on-device-model exchange (debug). Surface it as a collapsible
                    # item so the user can see exactly what ask_local/ask_local_batch
                    # sent to the local model and what it returned (e.g. why a
                    # phone-bill filter matched what it did). \n was escaped for the
                    # one-line sentinel — restore it for readability.
                    var rec = String(ln.removeprefix(LOCAL_SENTINEL))
                    var sg = rec.split(LOCAL_SEP)
                    var sent = _unescape_nl(String(sg[0])) if len(
                        sg
                    ) >= 1 else String("")
                    var got = _unescape_nl(String(sg[1])) if len(
                        sg
                    ) >= 2 else String("")
                    conn.send_text(
                        debug_event(
                            "execute",
                            "on-device model — what it was asked",
                            "SENT:\n" + sent + "\n\nGOT:\n" + got,
                            "text",
                        )
                    )
                elif ln.startswith(RESULT_SENTINEL):
                    # The generated program's declarative RESULT SPEC (v:1 JSON). The
                    # builders re-emit after every mutation, so keep the LAST (complete)
                    # line; it's attached to the final message event. Not shown live
                    # (Phase 1 attaches the presentation at the end, below the words).
                    result_spec = String(ln.removeprefix(RESULT_SENTINEL))
            # Update the ONE 'working' line in place with the latest progress label
            # + running api/model tallies, whenever a progress or stat line arrived.
            if dirty:
                conn.send_text(
                    status(
                        "execute",
                        cur_label
                        + _live_stats(api_names, api_count, pf_tok, gen_tok),
                        "running",
                    )
                )
            if running:
                iters += 1
                if iters > _RUN_MAX_ITERS:
                    # A run must not stall the queue — kill a too-slow / stuck child.
                    _ = external_call["kill", Int32](h.pid, Int32(_SIGKILL))
                    timed_out = True
                    running = False
                    # Reap the corpse so it doesn't linger as a zombie. SIGKILL isn't
                    # instant (a child wedged in a syscall dies when it returns), so
                    # poll a few times before giving up.
                    for _r in range(25):
                        if orch.vault_run_reap(h) != -1:
                            break
                        _usleep(40_000)  # 40 ms
                else:
                    _usleep(120_000)  # 120 ms between polls

        log(
            "[run] poll done: iters="
            + String(iters)
            + " timed_out="
            + String(timed_out)
        )
        # Final per-category summary: total + throughput (number/sec) for every API
        # category (codegen-phase + vault tools) and the model (prefill/gen tokens).
        if len(api_names) > 0 or pf_tok + gen_tok > 0:
            var sum = String("Stats:")
            for i in range(len(api_names)):
                if api_count[i] == 1:
                    # One instance → the duration is more telling than a rate.
                    sum += "  " + api_names[i]
                    if api_ms[i] > 0.0:
                        sum += " (" + _dur(api_ms[i]) + ")"
                else:
                    sum += "  " + api_names[i] + " ×" + String(api_count[i])
                    if api_ms[i] > 0.0:  # repeated timed calls → a rate
                        sum += (
                            " ("
                            + _rate1(Float64(api_count[i]), api_ms[i])
                            + "/s)"
                        )
            if pf_tok > 0:
                sum += (
                    "  prefill "
                    + String(pf_tok)
                    + " tok ("
                    + _irate(Float64(pf_tok), pf_ms)
                    + " tok/s)"
                )
            if gen_tok > 0:
                sum += (
                    "  gen "
                    + String(gen_tok)
                    + " tok ("
                    + _irate(Float64(gen_tok), dec_ms)
                    + " tok/s)"
                )
            conn.send_text(status("engine", sum, "done"))

        # Past `poll done` the run is over, so a perceived "hang" on the SECOND
        # question must live in this tail — finish/read, the WS sends, or releasing
        # the queue slot. Bracket each step so the log shows exactly where it stalls.
        log("[run] finish: reading captured output")
        var reply = orch.vault_run_finish(h)
        log("[run] finish: reply " + String(reply.byte_length()) + "B")
        if timed_out:
            conn.send_text(
                status(
                    "execute",
                    "Stopped — the run exceeded the time limit",
                    "error",
                )
            )
            conn.send_text(
                message(
                    "That took too long and was stopped. Please try another"
                    " question."
                )
            )
        else:
            conn.send_text(
                status("execute", "Running it locally over your vault", "done")
            )
            conn.send_text(message(reply, src_file, src_alias, result_spec))
        log("[run] reply sent; releasing queue slot ticket=" + String(ticket))
        # Persist this question's usage (JSONL) for the Stats page — still inside the
        # run slot, so writes across workers are serialized. total = work time only
        # (pre-approval manifest+codegen + post-approval compile+run); the human pause
        # and queue wait are excluded so the average reflects the machine, not the user.
        _append_stats(
            _epoch_s(),
            question,
            _model_label(),
            _app_version(),
            not timed_out,
            pre_ms + _ms_since(t_run0),
            pf_tok,
            gen_tok,
            pf_ms,
            dec_ms,
            api_names,
            api_count,
            api_ms,
        )
        # The durable history store — same record, plus the generated program and
        # the answer, kept forever (the chat history panel reads it back).
        _append_ask(
            _epoch_s(),
            question,
            code,
            reply,
            src_file,
            _model_label(),
            not timed_out,
        )
        runq_done(ticket)  # leave the run slot → next waiter proceeds
        log("[run] queue slot released")
        # Between-questions worker: with the run slot already released, opportunistically
        # advance ML-tag backfill by ONE bounded generation-batch. Try-locked +
        # pause-aware + best-effort (a down engine just no-ops), so it can never delay
        # a question or fail the turn. Usually a fast no-op (nothing pending); it only
        # does real work when there's a backlog (a newly-added AI rule, or first run
        # after upgrade).
        try:
            var mchanged = ml_backfill_slice(_engine_url())
            if mchanged > 0:
                log("[backfill] slice tagged " + String(mchanged) + " txn(s)")
        except e:
            log("[backfill] slice skipped: " + String(e))
    except e:
        conn.send_text(error_event(String(e)))
        if ticket >= 0:
            runq_done(ticket)  # release the slot if we died mid-run
    conn.close(WsCloseCode.NORMAL)


def main() raises:
    var cfg = load_config()

    # Ensure the data dir exists (new macOS-native location; no migration) so the
    # first stats/asks/controller write doesn't race a missing directory.
    try:
        makedirs(_config_dir(), exist_ok=True)
        _chmod(
            _config_dir(), 0o700
        )  # owner-only: holds stats/asks/history + demo tokens
    except:
        pass

    # Ensure the local-capability secret exists (0600) so the native menu-bar app's
    # Touch-ID unlock can bridge to a reveal token. Skipped in the demo (no gate).
    try:
        if not _is_demo():
            _ = _ensure_reveal_secret()
    except:
        pass

    # VAULT-ONLY: build the vault orchestrator over the resolved vault dir
    # (HEADGATE_VAULT_DIR / $MILLFOLIO_VAULT / $HEADGATE_DATA / ~/millfolio) and route
    # /chat to run_vault_task.
    var vault_dir = resolve_vault_dir()
    print("millfolio server — VAULT mode — vault dir: " + vault_dir)
    var orch = build_vault_orchestrator(cfg, vault_dir)

    var st = MillfolioState(orch^, vault_dir^)
    var sp = alloc[MillfolioState](1)
    sp.init_pointee_move(st^)
    var api = Api(sp)

    var port = _port()
    print("millfolio server on http://127.0.0.1:", port, "  (flare)", sep="")
    print('  POST /chat   { "message": ... } -> { "reply": ... }')
    print("  GET  /api/vault  -> vault files + index stats")
    print("  POST /api/search { query, k } -> ranked hits")
    print(
        "  WS   (Upgrade)   -> streaming chat (status/approval/message events)"
    )
    # One listener serves both: the unary HTTP `Api` handler AND, for requests with
    # the WebSocket Upgrade headers, the streaming `on_connect` chat — no second port.
    # (The 2-arg serve overload is plain-function-only; we use a stateful Handler
    # struct, so set the WS handler on the config and use the Handler-typed serve.)
    runq_reset()  # clear any stale run-queue state from a prior process
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(port)))
    srv.config.ws_handler = on_connect
    # Run each chat WebSocket on its OWN detached thread (off the reactor).
    # A chat query blocks for ~30s–2min inside `on_connect` (codegen's Anthropic
    # call, then compile + the run-poll loop). Inline, that parks the whole reactor
    # worker, so the read-only API GETs (/api/system, /api/vault, …) pinned to that
    # worker stall for the entire query — the UI's System tab shows "Loading…".
    # Offloading frees the reactor to keep answering those GETs while the chat runs.
    # The sandboxed RUN stays serial regardless (the flock run-queue in on_connect);
    # only manifest+codegen now overlap across visitors — desired for the demo.
    # MILLFOLIO_WS_INLINE=1 restores the old inline (reactor-blocking) behaviour.
    if getenv("MILLFOLIO_WS_INLINE", "") == "":
        srv.config.ws_offload = True
    var workers = _workers()
    if workers > 1:
        print(
            "  workers: ",
            workers,
            (
                " (concurrent connections; the sandboxed run stays serial via"
                " the run-queue)"
            ),
            sep="",
        )
    # Background AI-tag backfill: a DETACHED thread drains pending classification
    # in bounded slices so an AI tag backfills on its own (survives a closed browser)
    # WITHOUT blocking the reactor. Best-effort — backfill also runs at index time
    # and via the System → Backfill panel, so a spawn failure isn't fatal.
    try:
        var mth = ThreadHandle.spawn[_backfill_worker](_null_ptr())
        mth.detach()
        print("  background backfiller: on (AI tags backfill automatically)")
    except:
        print(
            "  background backfiller: could not start (index-time still works)"
        )
    # Background weight provisioner: ensure the required embedding model + a default
    # chat model are present (both no-ops when cached), so indexing/search + chat work
    # out of the box after a weights-free install; then kickstart the engine to serve
    # the default model. Detached — never blocks startup. Skipped in the demo (shared
    # replay engine, synthetic data). No-op when the downloader isn't configured.
    if not _is_demo():
        try:
            var pth = ThreadHandle.spawn[_provision_worker](_null_ptr())
            pth.detach()
            print(
                "  weight provisioner: on (embedding + default chat model,"
                " background)"
            )
        except:
            print("  weight provisioner: could not start")
    # num_workers=1 (default) → single-threaded reactor (real product). >1 → N pthread
    # workers via the multicore Handler-serve; Api is Copyable (shares the state
    # pointer) and config.ws_handler propagates to each worker.
    srv.serve(api^, num_workers=workers)
