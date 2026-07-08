"""handlers_chat — the chat surface: the unary `/chat` handler + the WS ask loop.

The two ways a question reaches the vault orchestrator:
  • POST /chat      — one-shot: run the full codegen loop, return `{ "reply": … }`.
  • WS   (Upgrade)  — streaming chat: status/debug/approval/message events per
                      stage, the sandbox run gated on the user's approval, plus
                      the "Run again" path (re-run a saved program, no model call).

Phase-1B tail: the last handler carve-out of server.mojo. `Api.handle_chat` was a
state-pointer method → the free `handle_chat(st, req)` here (same pattern as
`handlers_vault.handle_vault`); `on_connect` + its helper cluster (the stats/ask
JSONL appenders, the rate/duration formatters, the program tag scanners, `WsSink`)
are pure moves. One deliberate dedup: server.mojo's local `_json_escape` was
byte-identical to `events.json_escape`, so `handle_chat` now calls the shared one.
Behaviour is identical. server.mojo keeps only the route dispatcher + `main()`,
and wires `srv.config.ws_handler = handlers_chat.on_connect`.

Acyclic like every handler module: imports `state` + the leaf seams
(`osutil`/`auth`/`httputil`/`events`/`runqueue`/`vault.storage`/`work_orchestrator`),
never `server`.
"""

from std.memory import UnsafePointer
from std.os import getenv

from flare.prelude import *
from flare.ws import WsConnection, WsOpcode, WsCloseCode

from std.ffi import external_call
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
from runqueue import runq_take, runq_peek, runq_done

# The stats + ask history stores — the two JSONL sinks the chat WS loop appends to.
from vault.storage import default_stats_store, default_asks_store

# The poll-loop sleep shared with the work orchestrator's scheduler loop.
from work_orchestrator import _usleep

# The category tag NAMES + scope notes the chat WS loop surfaces to codegen (never
# the keyword RULES — those stay on-device).
from vault.derive.tags import effective_tags, effective_tag_descriptions
from vaultcfg import vault_dir as resolve_vault_dir
from state import MillfolioState
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
from record_builders import ask_record_line
from json import loads

from osutil import _is_demo, _epoch_s, _model_label, _app_version
from auth import _apply_persisted_apikey, _turnstile_enabled, _demo_token_valid
from httputil import _cors, _extract_host, _host_allowed


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


def handle_chat(
    st: UnsafePointer[MillfolioState, MutUntrackedOrigin], req: Request
) raises -> Response:
    """POST /chat — one-shot: run the private-vault codegen loop over the served
    vault dir and return the answer. Needs the long-lived orchestrator off
    `MillfolioState`, so it takes the state pointer (like `handle_vault`)."""
    ref s = st[]
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
    return _cors(ok_json('{"reply":' + json_escape(reply) + "}"))


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
