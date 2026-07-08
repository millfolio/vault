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
from std.os import getenv, makedirs


from flare.prelude import *
from flare.http import Handler
from flare.ws import WsConnection, WsOpcode, WsCloseCode
from flare.runtime._thread import ThreadHandle, _null_ptr

from std.ffi import external_call
from std.sys import argv
from std.time import perf_counter_ns

from settings import load_config
from wiring import build_vault_orchestrator
from orchestrator import (
    PROGRESS_SENTINEL,
    STAT_SENTINEL,
    LOCAL_SENTINEL,
    LOCAL_SEP,
    RESULT_SENTINEL,
)
from transport import DeltaSink
from runqueue import runq_take, runq_peek, runq_done, runq_reset

# The stats + ask history stores — the two JSONL sinks the chat WS loop appends to.
from vault.storage import default_stats_store, default_asks_store

# The work orchestrator's runtime (Phase 3 slice): the scheduler loop + its job
# runners live in their own module. server.mojo keeps the chat WS surface and imports
# the spawn entry point (`_orchestrator_worker`), the boot reconcile (`_reconcile_stale`),
# and the poll-loop sleep (`_usleep`). The per-domain handler modules import the rest of
# the orchestrator's state/op readers. work_orchestrator never imports server.mojo (acyclic).
from work_orchestrator import _orchestrator_worker, _reconcile_stale, _usleep

# The category tag NAMES + scope notes the chat WS loop surfaces to codegen (never the
# keyword RULES — those stay on-device). The rest of the LanceDB-free registry/tags
# store is imported by the per-domain handler modules.
from vault.derive.tags import effective_tags, effective_tag_descriptions
from vaultcfg import vault_dir as resolve_vault_dir
from state import MillfolioState
import handlers_vault
import handlers_apikey
import handlers_system
import handlers_amounts
import handlers_tags
import handlers_models
import handlers_demo
import handlers_operations
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
from store import ask_record_line
from json import loads

# The extracted free-helper modules (Phase-1 slice A). `osutil` is the BASE
# (stdlib-only) layer the others build on — no import cycle. See each module's
# docstring for what lives where.
from osutil import (
    _port,
    _workers,
    _web_root,
    _config_dir,
    _chmod,
    _is_demo,
    _epoch_s,
    _model_label,
    _app_version,
)
from auth import (
    _ensure_reveal_secret,
    _apply_persisted_apikey,
    _turnstile_enabled,
    _demo_token_valid,
)
from httputil import (
    _content_type,
    _serve_file,
    _cors,
    _forbidden,
    _extract_host,
    _host_allowed,
)


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
            return handlers_vault.handle_vault(self.st)
        # Document viewer: /api/doc?alias=file_N streams the raw indexed file
        # (alias-gated via the manifest — no caller-supplied path, so no traversal).
        if path == "/api/doc" or (path.find("/api/doc?") == 0):
            return handlers_vault.handle_doc(req)
        if req.method == Method.POST and path == "/api/search":
            return handlers_vault.handle_search(req)
        if path == "/health":
            return handlers_system.handle_health()
        # The on-device model name — the UI shows it in the bottom bar.
        if path == "/api/model":
            return handlers_models.handle_model_info()
        # On-device model selector: the list of switchable (cached) models + the
        # current selection; POST /api/models/select switches it (restarts engine).
        if path == "/api/models":
            return handlers_models.handle_models_list()
        if req.method == Method.POST and path == "/api/models/select":
            return handlers_models.handle_model_select(req)
        # Model catalog downloads: start a background fetch of a supported model's
        # weights, and poll its progress.
        if req.method == Method.POST and path == "/api/models/download":
            return handlers_models.handle_model_download(req)
        if path == "/api/models/download/status":
            return handlers_models.handle_models_download_status()
        # First-run onboarding: fetch + index the hosted sample vault so a new user
        # can try millfolio without pointing it at their own folder. Poll its progress.
        if req.method == Method.POST and path == "/api/demo/download":
            return handlers_demo.handle_demo_download()
        if path == "/api/demo/status":
            return handlers_demo.handle_demo_status()
        # Vault/Files: index an arbitrary local folder/file, track it, and re-index
        # tracked folders to pick up new files. One job at a time (shared with the
        # sample-vault import path). See handle_index for the append-not-clobber note.
        if req.method == Method.POST and path == "/api/index":
            return handlers_operations.handle_index(req)
        if path == "/api/index/status":
            return handlers_operations.handle_index_status()
        if path == "/api/operations":
            return handlers_operations.handle_operations()
        # The work-queue contents (running + pending) so Operations can show what's
        # queued behind the running job. Read-only; empty in the demo.
        if path == "/api/orchestrator/queue":
            return handlers_operations.handle_orchestrator_queue()
        if path == "/api/index/folders":
            return handlers_operations.handle_index_folders()
        if req.method == Method.POST and path == "/api/index/reindex":
            return handlers_operations.handle_index_reindex(req)
        if req.method == Method.POST and path == "/api/index/folders/remove":
            return handlers_operations.handle_index_folder_remove(req)
        # Demo bot gate: validate a Turnstile token → mint a demo-access token the
        # client echoes on WS chat frames. No-op (empty token) when Turnstile is off.
        if req.method == Method.POST and path == "/api/demo/verify":
            return handlers_demo.handle_demo_verify(req)
        # Instantaneous GPU utilization (%); the bottom bar keeps a 30s average.
        if path == "/api/gpu":
            return handlers_system.handle_gpu()
        # Accumulated per-question usage (JSONL file, returned verbatim) — the Stats page.
        if path == "/api/stats":
            return handlers_system.handle_stats()
        if path == "/api/history/delete":
            return handlers_system.handle_history_delete(req)
        if path == "/api/history":
            return handlers_system.handle_history()
        if path == "/api/system":
            return handlers_system.handle_system()
        # Category tags: the panel's list (names + keywords + per-tag counts) and
        # the editable registry file. All in-process via vault.derive.store.
        if path == "/api/tags":
            return handlers_tags.handle_tags()
        if path == "/api/transactions" or path.find("/api/transactions?") == 0:
            return handlers_amounts.handle_transactions(req)
        # WebAuthn (Touch-ID) gate for revealing transaction amounts.
        if req.method == Method.POST and path == "/api/auth/unlock":
            return handlers_amounts.handle_auth_unlock(req)
        if req.method == Method.POST and path == "/api/amounts/unlock-local":
            return handlers_amounts.handle_amounts_unlock_local(req)
        if path == "/api/categories/preview":
            return handlers_tags.handle_categories_preview(req)
        if path == "/api/categories":
            if req.method == Method.POST:
                return handlers_tags.handle_categories_save(req)
            return handlers_tags.handle_categories_get()
        if path == "/api/backfill/status":
            return handlers_tags.handle_backfill_status()
        if path == "/api/backfill/run":
            return handlers_tags.handle_backfill_run()
        # Pause + priority are now ORCHESTRATOR-GLOBAL (govern index AND backfill).
        # `/api/orchestrator/*` are the canonical routes; the `/api/backfill/*` ones
        # remain as thin aliases (both hit the same global controller) for one release.
        if path == "/api/orchestrator/pause" or path == "/api/backfill/pause":
            return handlers_tags.handle_backfill_pause(req)
        if path == "/api/orchestrator/resume" or path == "/api/backfill/resume":
            return handlers_tags.handle_backfill_resume()
        if (
            path == "/api/orchestrator/priority"
            or path == "/api/backfill/priority"
        ):
            return handlers_tags.handle_backfill_priority(req)
        if path == "/api/tags/preview-ai":
            return handlers_tags.handle_tags_preview_ai(req)
        if path == "/api/tags/add":
            return handlers_tags.handle_tags_add(req)
        if path == "/api/tags/missing-defaults":
            return handlers_tags.handle_tags_missing_defaults()
        if path == "/api/tags/add-defaults":
            return handlers_tags.handle_tags_add_defaults(req)
        # In-app Anthropic API key (for native users who never set the env var):
        # GET → {set, hint}; POST {key} → store 0600 (empty key clears); DELETE → clear.
        if path == "/api/settings/apikey":
            if req.method == Method.POST:
                return handlers_apikey.handle_apikey_post(req)
            if req.method == Method.DELETE:
                return handlers_apikey.handle_apikey_delete()
            return handlers_apikey.handle_apikey_get()
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
        + "}"
    )
    try:
        # the store appends the "\n" (JSONL) + chmods 0600 (owner-only: the record
        # holds the full question text) — same two calls as before.
        default_stats_store().append(line)
    except:
        log("[stats] append failed (non-fatal)")


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
        default_asks_store().append(line)  # +"\n" + chmod 0600, in the store
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
    # Two client frames open a session: an "ask" (codegen → approve → run) or a "run" —
    # the "Run again" path, which re-runs a SAVED program (from the chat history) over
    # the CURRENT vault with NO model call. Both stream the SAME events; only how we
    # obtain the program to run differs (codegen vs. supplied), so the compile+run tail
    # below is shared.
    var msg_type = field(frame.text_payload(), "type")
    var is_run = msg_type == "run"
    var question = field(frame.text_payload(), "text")
    var supplied_program = String("")
    if is_run:
        # Re-run a stored program directly. Rejected in the replay demo: it only answers
        # the curated questions via the codegen replay cache — there is no arbitrary-
        # program run path there (and its data is synthetic + public anyway).
        if _is_demo():
            conn.send_text(
                error_event('"Run again" is not available in the demo')
            )
            conn.close(WsCloseCode.NORMAL)
            return
        supplied_program = field(frame.text_payload(), "program")
        if supplied_program == "":
            conn.send_text(error_event("empty or malformed run"))
            conn.close(WsCloseCode.NORMAL)
            return
        if question == "":
            question = String("(re-run)")  # for the stats/history record
    else:
        if question == "":
            conn.send_text(error_event("empty or malformed ask"))
            conn.close(WsCloseCode.NORMAL)
            return
        # Demo bot gate: require a valid demo-access token (minted after a Turnstile
        # solve) on every ASK frame. Server-enforced, so a bot can't skip the client
        # widget. No-op when the gate is off (real product / local dev / no secret).
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
        # Fall back to the in-app key store when the env supplied none, so a key
        # pasted into the Settings field takes effect on this very next question.
        _apply_persisted_apikey(cfg)
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
        var code: String
        if is_run:
            # "Run again": no manifest, no codegen, no model call — the program
            # is supplied by the client (a program saved from a prior ask). Skip
            # straight to the shared compile + run tail. No approval gate: it was
            # reviewed when first asked and is re-run unchanged over the CURRENT
            # vault (deterministic — the whole point of Run again).
            code = supplied_program.copy()
            pre_ms = 0.0
        else:
            conn.send_text(
                status("manifest", "Aliasing vault manifest", "running")
            )
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
            conn.send_text(
                status("manifest", "Aliasing vault manifest", "done")
            )

            conn.send_text(status("codegen", "Writing the program", "running"))
            _t = perf_counter_ns()
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
                approval(
                    "run", "Run the generated program over your vault?", code
                )
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
        conn.send_text(
            status(
                "run",
                "Re-running the saved program" if is_run else "Approved — running",
                "done",
            )
        )
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
        # AI-tag backfill is NOT run inline here anymore: the work orchestrator owns ALL
        # background engine work (one job at a time), so firing a slice from the query
        # path would bypass its serialization and re-introduce index/backfill contention.
        # With the run slot released, the orchestrator picks up any pending backfill on
        # its next idle tick.
    except e:
        conn.send_text(error_event(String(e)))
        if ticket >= 0:
            runq_done(ticket)  # release the slot if we died mid-run
    conn.close(WsCloseCode.NORMAL)


def main() raises:
    # `--fetch-demo <url> <dest>`: NOT the server — a one-shot download helper we re-exec
    # as a SEPARATE PROCESS from the orchestrator loop (see `_demo_fetch_and_unpack`), so
    # the sample-vault zip's flare GET runs off the serving reactor. Do the fetch + exit
    # before any server/orchestrator setup (never binds the port). The parent reads
    # success from the written file, so the return value is advisory only.
    var cli = argv()
    if len(cli) >= 2 and String(cli[1]) == "--fetch-demo":
        var url = String(cli[2]) if len(cli) >= 3 else String("")
        var dest = String(cli[3]) if len(cli) >= 4 else String("")
        _ = handlers_demo._fetch_demo_run(url, dest)
        return

    var cfg = load_config()
    # The `/chat` orchestrator is built once here from this cfg, so seed it from
    # the in-app key store too (the WS ask path re-loads per connection). A key
    # pasted later still lands via the per-connection reload on the WS path.
    _apply_persisted_apikey(cfg)

    # Ensure the data dir exists (new macOS-native location; no migration) so the
    # first stats/asks/controller write doesn't race a missing directory.
    try:
        makedirs(_config_dir(), exist_ok=True)
        _chmod(
            _config_dir(), 0o700
        )  # owner-only: holds stats/asks/history + demo tokens
    except:
        pass

    # Crash recovery: reconcile any work items a prior (now-dead) process left marked
    # running — an orphaned index run settles to `error` and clears; the work queue
    # itself survives the restart and RESUMES its pending items (see the loop below).
    _reconcile_stale()

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
    # The work orchestrator: ONE detached scheduler loop drains the disk-backed work
    # queue — ALL background engine work (indexing + AI-tag backfill) — a single job at
    # a time, honoring the global pause + priority and yielding to interactive queries.
    # This replaces both the free-poll backfill thread and the direct index-spawn, so
    # index and backfill can never contend for the engine (see ORCHESTRATOR.md §2.3).
    try:
        var mth = ThreadHandle.spawn[_orchestrator_worker](_null_ptr())
        mth.detach()
        print(
            "  work orchestrator: on (indexing + AI-tag backfill, one at a"
            " time)"
        )
    except:
        print(
            "  work orchestrator: could not start (index-time backfill still"
            " works)"
        )
    # Background weight provisioner: ensure the required embedding model + a default
    # chat model are present (both no-ops when cached), so indexing/search + chat work
    # out of the box after a weights-free install; then kickstart the engine to serve
    # the default model. Detached — never blocks startup. Skipped in the demo (shared
    # replay engine, synthetic data). No-op when the downloader isn't configured.
    if not _is_demo():
        try:
            var pth = ThreadHandle.spawn[handlers_models._provision_worker](
                _null_ptr()
            )
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
