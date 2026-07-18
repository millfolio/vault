"""handlers_demo — the first-run sample-vault import (+ the demo bot gate).

A new user with an empty vault can "try it with sample data": the import is a
single `demo-download` work item the scheduler loop drains — it fetches the
small hosted zip (MILLFOLIO_DEMO_URL) in a SEPARATE PROCESS, unpacks it, then
enqueues a normal per-file index run over it, so the whole import flows through
the ONE scheduler and surfaces in Operations.
  • POST /api/demo/download — enqueue the sample-vault import.
  • GET  /api/demo/status   — poll the import's progress.
  • POST /api/demo/verify   — validate a Turnstile token → mint a demo-access token.

Phase-1B slice 2: pure moves of the `Api.handle_demo_*` methods (and the inline
`/api/demo/status` route body, now a free `handle_demo_status`) plus the
`_demo_*` / `_write_demo_pending_op` / `_finalize_demo_op` / `_fetch_demo_run`
helper cluster. None deref `self.st`; the `self`-qualified helper calls resolve
to the already-extracted leaf modules (`osutil`, `auth`, `httputil`, `events`,
`vault.storage`, `scheduler_loop`, `scheduler`, `work_queue`).
`scheduler_loop` never imports this module, so it stays acyclic.
`server._route` delegates here; `server.main` calls `_fetch_demo_run` for its
`--fetch-demo` mode, and `handlers_operations.handle_operations` calls
`_finalize_demo_op`. Behaviour is identical.
"""

from std.os import getenv, remove
from std.ffi import external_call, c_int

from flare.prelude import *
from flare.http import HttpClient

from json import loads

from vault.storage import default_kv_store, KV_DEMO_STATE, KV_DEMO_OP
from scheduler_loop import (
    _kv_set,
    _write_small,
    _demo_dir,
    _demo_log_path,
    _demo_present,
    _wq_list_safe,
    _index_read_state_raw,
    _index_progress,
    _read_runtotal,
    _append_operation,
    _indexed_file_count,
    _stored_txn_count,
)
from scheduler import index_active, index_current, KIND_DEMO
from work_queue import wq_enqueue, wq_list, PRIO_INDEX

from osutil import _config_dir, _cstr, _is_demo, _epoch_s
from auth import _turnstile_enabled, _verify_turnstile, _mint_demo_token
from events import json_escape
from httputil import unauthorized, _cors


# ── HTTP handlers ────────────────────────────────────────────────────────────


def handle_demo_verify(req: Request) raises -> Response:
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
        return _cors(unauthorized('{"error":"turnstile verification failed"}'))
    return _cors(ok_json('{"ok":true,"token":"' + _mint_demo_token() + '"}'))


def handle_demo_download() raises -> Response:
    """POST /api/demo/download → import the hosted sample vault
    (MILLFOLIO_DEMO_URL, default https://millfolio.app/demo-vault.zip): ENQUEUE a
    single `demo-download` work item and return immediately. The scheduler loop
    then downloads + unpacks it into `<data>/demo-vault/` (in a `--fetch-demo`
    subprocess, off-reactor), then enqueues a normal per-file index run over it — so
    the whole
    import flows through the ONE scheduler and shows in Operations (the download as a
    job, then the per-file indexing). The client polls /api/demo/status. Idempotent:
    a finished import no-ops to done. Disabled in the public replay demo (its vault
    is fixed + synthetic). Indexing needs the engine runner (MILLFOLIO_RUN_SCRIPT),
    so we 400 when it isn't configured."""
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
    if _demo_present() and _demo_effective_state() == "done":
        return _cors(ok_json('{"ok":true,"state":"done"}'))
    if _demo_running():
        return _cors(
            bad_request('{"error":"sample data import already running"}')
        )
    # Mark downloading synchronously (so an immediate status poll / re-POST sees it
    # in flight), stamp the pending Operations row, then enqueue the work item. The
    # scheduler loop picks it up and does the actual fetch + index off-reactor.
    _kv_set(KV_DEMO_STATE, "downloading")
    _write_small(_demo_log_path(), "Downloading sample data…")
    _write_demo_pending_op(_epoch_s())
    try:
        _ = wq_enqueue(String(KIND_DEMO), _demo_dir(), _epoch_s(), PRIO_INDEX)
    except:
        _kv_set(KV_DEMO_STATE, "error")
        return _cors(
            bad_request('{"error":"could not start sample data import"}')
        )
    return _cors(ok_json('{"ok":true,"state":"downloading"}'))


def handle_demo_status() raises -> Response:
    """GET /api/demo/status → the sample-vault import's settled status."""
    return _cors(ok_json(_demo_status_json()))


# ── sample-vault import state ─────────────────────────────────────────────────
# State is tracked in small files the status endpoint reports; the whole import is
# recorded as ONE `demo` operation (the index run reuses `_start_index_run` with
# `record_op=False`).


def _demo_state_path() -> String:
    return (
        _config_dir() + "/" + KV_DEMO_STATE
    )  # downloading|indexing|done|error


def _demo_op_path() -> String:
    """Marker written when the sample-data import STARTS (its kind + start epoch),
    read back once the import settles to record ONE operation-history row — the same
    lazy-finalize pattern index/reindex runs use (`_pending_op_path`). The full path is
    still used for the atomic-rename claim in `_finalize_demo_op`."""
    return _config_dir() + "/" + KV_DEMO_OP


def _demo_read_state() -> String:
    try:
        return String(default_kv_store().get(KV_DEMO_STATE).strip())
    except:
        return String("idle")


def _demo_effective_state() -> String:
    """The sample-data import's state, SETTLED against the index queue. While the raw
    `.demo.state` file says `indexing`, the actual per-file work runs as a normal index
    run through the scheduler — so the demo is still `indexing` while any index-family
    item is queued/running, and once that drains it reflects the index run's outcome
    (`done`, or `error` if a step failed). The settled outcome is persisted back to
    `.demo.state` so the import records its Operations row exactly once. Other raw states
    (downloading/done/error/idle) pass through unchanged."""
    var raw = _demo_read_state()
    if raw != "indexing":
        return raw^
    if index_active(_wq_list_safe()):
        return String("indexing")
    # The index run settled — reflect + persist its outcome.
    if _index_read_state_raw() == "error":
        _kv_set(KV_DEMO_STATE, "error")
        return String("error")
    _kv_set(KV_DEMO_STATE, "done")
    return String("done")


def _demo_running() -> Bool:
    """True while the import is genuinely in flight (downloading or indexing).
    """
    var st = _demo_effective_state()
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
    """{"state","detail","present","progress","bytesDone","bytesTotal"[,"current",
    "total"]} for the sample-vault import. `state` (settled via `_demo_effective_state`)
    is idle|downloading|indexing|done|error; `present` is whether the folder exists.

    The zip is tiny, so DOWNLOADING is a single full-body GET (in the `--fetch-demo`
    subprocess) with no incremental byte progress → `progress`/bytesDone/bytesTotal stay
    -1 (the client shows a spinner).
    While INDEXING, the per-file work runs as a normal index run through the scheduler,
    so we surface its `current`/`total` files (the SAME queue-derived count as
    /api/index/status) plus a `progress` percent, mirroring the download → indexing n/M
    onboarding progress. Also finalizes the operations-history row once settled (see
    `_finalize_demo_op`)."""
    _finalize_demo_op()
    var state = _demo_effective_state()
    var detail = _demo_progress()
    var progress = -1
    var idx_current = -1
    var idx_total = -1
    if state == "indexing":
        detail = _index_progress()  # the indexer's `[k/M] name` per-file line
        var total = _read_runtotal()
        if total > 0:
            idx_total = total
            idx_current = index_current(total, wq_list())
            var pct = (idx_current * 100) // total
            if pct < 0:
                pct = 0
            if pct > 99:
                pct = 99  # 100 only once the run is genuinely done
            progress = pct
    elif state == "done":
        progress = 100
    var out = (
        '{"state":'
        + json_escape(state)
        + ',"detail":'
        + json_escape(detail)
        + ',"present":'
        + ("true" if _demo_present() else "false")
        + ',"progress":'
        + String(progress)
        + ',"bytesDone":-1,"bytesTotal":-1'
    )
    if idx_total > 0:
        out += ',"current":' + String(idx_current)
        out += ',"total":' + String(idx_total)
    out += "}"
    return out^


def _write_demo_pending_op(started: Int64):
    """Stamp the pending-operation marker for a just-launched sample-data import.
    """
    _kv_set(
        KV_DEMO_OP,
        String('{"type":"demo","started":') + String(started) + "}",
    )


def _finalize_demo_op():
    """If the sample-data import has SETTLED (state done|error) and its pending marker
    is still present, record ONE `demo` operation for it and clear the marker. The
    marker is claimed with an atomic rename so whichever caller (a status poll or a GET
    /api/operations) wins records the run exactly once. Best-effort; never raises.
    """
    if not default_kv_store().exists(KV_DEMO_OP):
        return
    var state = _demo_effective_state()
    if state != "done" and state != "error":
        return  # still downloading / indexing — nothing settled to record yet
    var claimed = _demo_op_path() + ".claiming"
    var op = _cstr(_demo_op_path())
    var cl = _cstr(claimed)
    var rc = external_call["rename", c_int](op, cl)
    op.free()
    cl.free()
    if Int(rc) != 0:
        return  # another caller already claimed it (or it vanished)
    var started = Int64(0)
    try:
        var text: String
        with open(claimed, "r") as f:
            text = f.read()
        var j = loads(text)
        started = j["started"].int_value()
    except:
        pass
    var finished = _epoch_s()
    if started <= 0 or (finished - started) > Int64(86400):
        started = finished  # missing / stale marker → clamp to ~0s (see _finalize_index_op)
    _append_operation(
        String("demo"),
        started,
        finished,
        state,
        _demo_progress(),
        _indexed_file_count(),
        _stored_txn_count(),
        -1,  # tagged: n/a for a sample-data import
    )
    try:
        remove(claimed)
    except:
        pass


def _fetch_demo_run(url: String, dest: String) -> Bool:
    """Body of the `millfolio-server --fetch-demo <url> <dest>` mode: GET `url` with
    flare (in THIS separate process — off the server's serving reactor) and write the
    bytes to `dest`. Prints a short status line (captured into the demo log by the
    caller's `>>` redirect). Returns False on any HTTP/write failure; the parent treats a
    missing/empty `dest` as the error signal, so we simply do NOT write the file on a
    non-200/exception."""
    if url == "" or dest == "":
        print("fetch-demo: usage: --fetch-demo <url> <dest>")
        return False
    try:
        var req = Request(method="GET", url=url)
        var client = HttpClient()  # follows redirects (millfolio.app → asset)
        var resp = client.send(req)
        if resp.status != 200:
            print("Download failed (HTTP " + String(resp.status) + ")")
            return False
        with open(dest, "w") as f:
            f.write_bytes(Span(resp.body))
        print("Downloaded sample data (" + String(len(resp.body)) + " bytes)")
        return True
    except e:
        print("Download error: " + String(e))
        return False
