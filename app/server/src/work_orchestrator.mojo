"""work_orchestrator — the app server's background-work runtime (Phase 3 slice).

Lifts the WORK ORCHESTRATOR — the single scheduler loop plus its job runners —
out of the server.mojo god-file, completing the orchestrator's isolation (the
queue/scheduler/runqueue seams already live in `work_queue`/`scheduler`/
`runqueue`). This module OWNS all background engine work: the `_orchestrator_worker`
pthread loop drains the disk-backed work queue ONE item at a time — indexing
(prepare → per-file embed → finalize) AND AI-tag backfill AND the sample-vault
import — honoring a global pause + priority and yielding to interactive queries,
so index and backfill can never contend for the engine (ORCHESTRATOR.md §2.3).

It also owns the run STATE + OPERATIONS RECORDING the runners read/write: the
index/demo `.state`/pid/runtotal/pending-op markers, the operations.jsonl append,
and the `_start_index_run` generator (enumerate files → enqueue per-file items).

Pure move out of server.mojo — behaviour is byte-for-byte identical. server.mojo
still SPAWNS the loop (`ThreadHandle.spawn[_orchestrator_worker]`) and keeps the
HTTP surface (the `/api/orchestrator/*`, `/api/index|reindex`, `/api/demo/download`
handlers + the status-JSON builders), importing the enqueue/run/state helpers back
from here. Acyclic: this module imports the leaf seams (work_queue, scheduler,
runqueue, vault.storage, vault.derive.*, vault.index.manifest, osutil, store,
events, logging, json) — never server.mojo.
"""

from std.memory import alloc, UnsafePointer
from std.os import getenv, remove
from std.os.path import isfile, isdir, exists, getsize
from std.ffi import external_call, c_char, c_int

from flare.runtime._thread import _OpaquePtr

from runqueue import runq_peek
from work_queue import (
    WorkItem,
    wq_enqueue,
    wq_peek,
    wq_take,
    wq_done,
    wq_fail,
    wq_list,
    PRIO_BACKFILL,
)
from scheduler import (
    EnqSpec,
    index_run_plan,
    split_payload,
    index_current,
    index_active,
    query_active,
    should_reconcile,
    parse_pending_total,
    is_index_kind,
    KIND_PREPARE,
    KIND_INDEX,
    KIND_FINALIZE,
    KIND_BACKFILL,
    KIND_DEMO,
)
from vault.storage import (
    default_kv_store,
    default_operations_store,
    default_indexed_paths_store,
    default_manifest_store,
    KV_INDEX_STATE,
    KV_INDEX_OP,
    KV_INDEX_RUNTOTAL,
    KV_DEMO_STATE,
    DOC_INDEXED_PATHS,
    DOC_MANIFEST,
)
from vault.derive.tags import load_txn_rows
from vault.derive.store import (
    ml_backfill_slice,
    is_paused,
    get_priority,
    nap_ms_for_priority,
    backfill_status_json,
)
from vault.index.manifest import (
    common_base,
    collect_index_paths,
    manifest_for_files,
)
from osutil import _config_dir, _cstr, _epoch_s, _is_demo, _engine_url
from record_builders import operation_record_line
from events import json_escape
from logging import log
from json import loads


def _usleep(usec: Int):
    """Sleep `usec` microseconds (libc usleep) — the gap between run-output polls
    in the streaming loop, so we don't busy-spin while the sandboxed child runs.
    """
    _ = external_call["usleep", Int](Int(usec))


def _contains_str(haystack: List[String], needle: String) -> Bool:
    """Membership test for a String list (dedup helper — non-raising)."""
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


def _backfill_detail(tags: List[String]) raises -> String:
    """The Operations detail for a drained backfill session: the AI tag NAME(s) it
    applied, e.g. "AI-tag backfill complete: coffee shop, dining". Capped so a broad
    run doesn't produce an unwieldy line; falls back to the static text when no names
    were captured (older path / nothing reported)."""
    if len(tags) == 0:
        return String("AI-tag backfill complete")
    var cap = 6
    var shown = len(tags)
    if shown > cap:
        shown = cap
    var out = String("AI-tag backfill complete: ")
    for i in range(shown):
        if i > 0:
            out += ", "
        out += tags[i]
    if len(tags) > cap:
        out += ", …"
    return out^


def _getpid() -> Int:
    """This server process's pid — stamped as the running item's worker pid. The loop
    runs each item SYNCHRONOUSLY (an in-process slice, or a blocking child), so while
    an item is running this process is alive; if the server dies, an un-detached child
    dies with it — so server-pid liveness == item liveness (see `_reconcile_stale`).
    """
    return Int(external_call["getpid", Int32]())


def _reconcile_stale():
    """Crash recovery (loop head + on boot): a `running` work item whose recorded
    worker pid is provably DEAD is orphaned — its run died mid-flight. Generalizes the
    old `_reconcile_index_state_on_boot` PID-liveness guard to the whole queue.

    A dead backfill item is simply dropped (the old free-poll recorded nothing for an
    interrupted slice). A dead index-family item orphans the WHOLE index run: drop every
    index/prepare/finalize item, settle the state to `error`, and record one failed
    `index`/`reindex` op so Operations shows it plainly instead of a phantom running row.
    Best-effort; never raises (a pthread start routine must not)."""
    try:
        var items = wq_list()
        var index_orphaned = False
        for i in range(len(items)):
            if items[i].state != "running":
                continue
            if should_reconcile(items[i].state, _pid_alive(items[i].pid)):
                if is_index_kind(items[i].kind):
                    index_orphaned = True
                else:
                    _ = wq_fail(items[i].id, String("worker pid dead"))
        if index_orphaned:
            for i in range(len(items)):
                if is_index_kind(items[i].kind):
                    _ = wq_fail(items[i].id, String("index run orphaned"))
            _kv_set(KV_INDEX_STATE, "error")
            _finalize_index_op()  # attribute the failed run from its pending marker
    except:
        pass


def _run_index_child(subcmd: String, tail_args: List[String]) -> Bool:
    """Run a LanceDB-touching index step as a blocking child via MILLFOLIO_RUN_SCRIPT
    (`/bin/bash <run_script> <subcmd> <args…>`), output appended to the index log. The
    loop blocks here so exactly one job touches the engine at a time. Full environ is
    inherited (the embedding endpoint is reachable), unlike the sandboxed codegen path.
    Returns True on a clean exit (status 0)."""
    var run_script = String(getenv("MILLFOLIO_RUN_SCRIPT", "").strip())
    if run_script == "":
        return False
    var cmd: String
    try:
        cmd = String("/bin/bash ") + _sh_squote(run_script) + " " + subcmd
        for i in range(len(tail_args)):
            cmd += " " + _sh_squote(tail_args[i])
        cmd += " >> " + _sh_squote(_index_log_path()) + " 2>&1"
    except:
        return False
    var cc = _cstr(cmd)
    var rc = external_call["system", Int32](cc)  # BLOCKS (no trailing &)
    cc.free()
    return Int(rc) == 0


def _orchestrator_worker(arg: _OpaquePtr) -> _OpaquePtr:
    """The single background scheduler loop (ORCHESTRATOR.md §2.3). Replaces the old
    free-poll `_backfill_worker`: it owns ALL background engine work — indexing AND
    AI-tag backfill — draining the disk-backed work queue ONE item at a time so index
    and backfill can never contend for the engine again (the §1 stall is structurally
    impossible). Honors a GLOBAL pause + priority (both kinds), and yields to any
    interactive chat/ask. A pthread start routine must NEVER raise — swallow everything.

    A backfill "session" = a contiguous stretch of slices that tagged rows; when it
    drains (a slice tags nothing after the session tagged something) we append ONE
    `backfill` op for the whole session — same accounting as the old worker, now driven
    by queue items instead of a free poll."""
    var session_started = Int64(0)  # 0 = no active backfill session
    var session_tagged = 0
    var session_tags = List[String]()  # union of tag NAMES tagged this session
    while True:
        var idle_us = nap_ms_for_priority_safe() * 1000
        try:
            # 1. crash recovery — orphaned running items from a dead process.
            _reconcile_stale()
            # 2. GLOBAL pause — halts index AND backfill (queries are never paused).
            if is_paused():
                _usleep(500000)  # 0.5s tick
                continue
            # 3. yield to an interactive chat/ask holding (or waiting on) the engine.
            var ht = runq_peek()
            if query_active(ht[0], ht[1]):
                _usleep(200000)  # 0.2s — re-check soon
                continue
            # 4. pick the next item (prio: index/finalize before backfill; FIFO within).
            var item_opt = wq_peek()
            if not item_opt:
                # Nothing queued → let the backfill generator enqueue if ML work pends.
                _maybe_enqueue_backfill()
                _usleep(idle_us)
                continue
            var item = item_opt.value().copy()
            # 5. run exactly ONE item — take it (write the running marker) then dispatch.
            if not wq_take(item.id, _getpid(), _epoch_s()):
                continue  # lost the race (shouldn't happen — single loop)
            if item.kind == KIND_BACKFILL:
                var slice_tags = List[String]()
                var changed = ml_backfill_slice(_engine_url(), slice_tags)
                _ = wq_done(item.id)
                if changed > 0:
                    if session_started == 0:
                        session_started = _epoch_s()
                    session_tagged += changed
                    for i in range(len(slice_tags)):
                        if not _contains_str(session_tags, slice_tags[i]):
                            session_tags.append(slice_tags[i].copy())
                elif session_started != 0:
                    # Drained — record the session once, then reset (skip in the demo).
                    if not _is_demo():
                        _append_operation(
                            String("backfill"),
                            session_started,
                            _epoch_s(),
                            String("done"),
                            _backfill_detail(session_tags),
                            -1,
                            -1,
                            session_tagged,
                        )
                    session_started = 0
                    session_tagged = 0
                    session_tags = List[String]()
            elif item.kind == KIND_DEMO:
                _run_demo_download_item(item)
            else:
                _run_index_item(item)
            _usleep(idle_us)
        except:
            _usleep(idle_us)


def nap_ms_for_priority_safe() -> Int:
    """`nap_ms_for_priority(get_priority())` with a fallback (the loop's nap, in ms).
    """
    try:
        return nap_ms_for_priority(get_priority())
    except:
        return 1200


def _run_index_item(item: WorkItem):
    """Dispatch one index-family item. prepare/index-file/finalize each run as a blocking
    child (crash-isolated, engine-reachable); on any failure the whole run is aborted:
    the remaining index-family items are dropped, the state settles to `error`, and one
    failed op is recorded. On the finalize step's success the run settles to `done` and
    its op is attributed from the pending marker. Never raises."""
    try:
        var fields = split_payload(item.payload)
        if len(fields) == 0:
            _ = wq_done(item.id)
            return
        var base = fields[0].copy()
        var ok = False
        if item.kind == KIND_PREPARE:
            ok = _run_index_child(String("index-prepare"), [base])
        elif item.kind == KIND_INDEX:
            # Progress line for the status bar: [k/M] name (M = this run's file total).
            var total = _read_runtotal()
            var current = index_current(total, wq_list())
            var name = String(fields[1]) if len(fields) >= 2 else base
            try:
                with open(_index_log_path(), "a") as f:
                    f.write(
                        "["
                        + String(current)
                        + "/"
                        + String(total)
                        + "] "
                        + name
                        + "\n"
                    )
            except:
                pass
            var pth = String(fields[1]) if len(fields) >= 2 else base
            ok = _run_index_child(String("index-file"), [base, pth])
        elif item.kind == KIND_FINALIZE:
            var fargs = List[String]()
            fargs.append(base)
            for i in range(1, len(fields)):
                fargs.append(fields[i].copy())
            ok = _run_index_child(String("index-finalize"), fargs)
        if ok:
            _ = wq_done(item.id)
            if item.kind == KIND_FINALIZE:
                # The run settled cleanly — record the index/reindex op.
                _kv_set(KV_INDEX_STATE, "done")
                _finalize_index_op()
        else:
            _abort_index_run(item.kind + " step failed")
    except:
        _abort_index_run(String("index step error"))


def _abort_index_run(reason: String):
    """A failed index step aborts the run: drop the remaining index-family items, settle
    the state to `error`, and attribute the failed op from the pending marker.
    """
    try:
        var items = wq_list()
        for i in range(len(items)):
            if is_index_kind(items[i].kind):
                _ = wq_fail(items[i].id, reason)
        _kv_set(KV_INDEX_STATE, "error")
        _finalize_index_op()
    except:
        pass


def _maybe_enqueue_backfill():
    """The backfill generator (ORCHESTRATOR.md §2.1): when the queue is idle, enqueue
    ONE `backfill` slice item iff the readiness signal shows pending ML generations —
    nothing when idle. Dedup on (backfill, "slice") keeps at most one queued. The old
    free-poll ran a slice every tick regardless; this only queues real work."""
    try:
        if parse_pending_total(backfill_status_json()) > 0:
            _ = wq_enqueue(
                String(KIND_BACKFILL),
                String("slice"),
                _epoch_s(),
                PRIO_BACKFILL,
            )
    except:
        pass


def _write_small(path: String, text: String):
    """Best-effort single-file write (never raises). Still used for the captured-output
    LOGS (`.index.log` / `.demo.log`) and the tracked-paths doc — the single-value KV
    markers go through `_kv_set` (the storage seam) instead."""
    try:
        with open(path, "w") as f:
            f.write(text)
    except:
        pass


def _kv_set(key: String, value: String):
    """Best-effort single-value marker write (never raises) — the storage-seam facade
    (slice 3) that replaces `_write_small` for the KV markers. Swallows like the old
    `_write_small` did; `FileKvStore.set` itself raises, so the try/except lives here.
    """
    try:
        default_kv_store().set(key, value)
    except:
        pass


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


def _demo_log_path() -> String:
    return _config_dir() + "/.demo.log"  # captured download/unpack detail line


def _demo_present() -> Bool:
    """True once the sample vault has been unpacked (the folder exists)."""
    return isdir(_demo_dir())


def _run_demo_download_item(item: WorkItem):
    """Dispatch the one `demo-download` work item from the orchestrator loop (off the
    reactor). Download + unpack the sample vault, then hand the actual indexing to the
    orchestrator by enqueuing a normal per-file index run over `<data>/demo-vault/` —
    so the per-file embedding shows in Operations like any other index. On any failure
    the demo settles to `error`. Always `wq_done`s the item (a failed download isn't
    retried — the user can hit Retry). Never raises (a loop step must not)."""
    try:
        if _demo_fetch_and_unpack():
            # Hand off to the orchestrator: enqueue prepare → per-file index → finalize
            # over the demo dir. `record_op=False` so the whole import is ONE `demo` op,
            # not a separate `index` one. The loop drains these on the next iterations,
            # and `_demo_effective_state` settles the demo to done/error from that run.
            if _start_index_run([_demo_dir()], String("index"), False):
                _kv_set(KV_DEMO_STATE, "indexing")
                _write_small(
                    _demo_log_path(),
                    (
                        "Indexing sample data (first run loads the embedding"
                        " model)…"
                    ),
                )
            else:
                _kv_set(KV_DEMO_STATE, "error")
        else:
            _kv_set(KV_DEMO_STATE, "error")
        _ = wq_done(item.id)
    except:
        _kv_set(KV_DEMO_STATE, "error")
        try:
            _ = wq_done(item.id)
        except:
            pass


def _self_exe_path() -> String:
    """Absolute path to THIS running executable (the app-server binary) via macOS
    `_NSGetExecutablePath`. Used to re-spawn ourselves in `--fetch-demo` mode as a
    separate PROCESS, so the demo-zip download's flare client runs off the serving
    reactor. Empty on failure (the caller treats that as a download error)."""
    comptime CAP = 4096
    var buf = alloc[UInt8](CAP)
    var sizep = alloc[UInt32](1)
    sizep[0] = UInt32(CAP)
    var rc = external_call["_NSGetExecutablePath", Int32](buf, sizep)
    sizep.free()
    var out = String("")
    if Int(rc) == 0:
        var n = 0
        while n < CAP and buf[n] != 0:
            n += 1
        var bytes = List[UInt8]()
        for i in range(n):
            bytes.append(buf[i])
        out = String(StringSlice(unsafe_from_utf8=Span(bytes)))
    buf.free()
    return out^


def _demo_fetch_and_unpack() raises -> Bool:
    """Fetch the hosted sample-vault zip in a SEPARATE PROCESS — re-exec THIS server
    binary in `--fetch-demo` mode so flare's blocking HTTP client runs in that child,
    NEVER on the serving reactor (an in-loop flare GET can stall the shared reactor —
    the "History timed out" we saw). We run it from the orchestrator loop thread and
    BLOCK on it (safe — the loop is not the reactor); a written, non-empty
    `<data>/.demo-vault.zip` is the success signal (the child writes it only on a 200).
    Then unpack into `<data>/demo-vault/`. Returns True once the folder is present. The
    zip is tiny (~KB) so a single full-body GET is fine — no incremental byte progress.
    Unpack is a one-line `unzip` shell-out (macOS ships it). Best-effort; the caller
    treats a False/raise as an import error."""
    _kv_set(KV_DEMO_STATE, "downloading")
    _write_small(_demo_log_path(), "Downloading sample data…")
    var exe = _self_exe_path()
    if exe == "":
        _write_small(
            _demo_log_path(),
            "Download error: could not locate the server binary",
        )
        return False
    # Fresh zip each run: a stale/partial file must never be mistaken for a success.
    try:
        remove(_demo_zip_path())
    except:
        pass
    # Spawn the download as a child process (flare runs THERE, off our reactor) and
    # block the loop thread on it. Its stdout/stderr append to the demo log so
    # `_demo_progress` can surface a failure line as the status detail.
    var cmd = (
        _sh_squote(exe)
        + " --fetch-demo "
        + _sh_squote(_demo_url())
        + " "
        + _sh_squote(_demo_zip_path())
        + " >> "
        + _sh_squote(_demo_log_path())
        + " 2>&1"
    )
    var cc = _cstr(cmd)
    _ = external_call["system", Int32](
        cc
    )  # BLOCKS in the loop thread (off-reactor)
    cc.free()
    # A written, non-empty zip means the child fetch succeeded (it writes nothing on a
    # non-200/exception; a 0-byte file — empty 200 or a mid-write failure — is a miss).
    if not exists(_demo_zip_path()) or Int(getsize(_demo_zip_path())) <= 0:
        return False
    # Unpack: replace any prior copy, then extract the `demo-vault/` folder into the
    # data dir. `unzip -o` overwrites; ships with macOS (unlike a bundled `curl`).
    _write_small(_demo_log_path(), "Unpacking…")
    var ucmd = (
        "rm -rf "
        + _sh_squote(_demo_dir())
        + " && unzip -o "
        + _sh_squote(_demo_zip_path())
        + " -d "
        + _sh_squote(_config_dir())
        + " >/dev/null 2>&1"
    )
    var ucc = _cstr(ucmd)
    _ = external_call["system", Int32](ucc)  # BLOCKS (no trailing &)
    ucc.free()
    return _demo_present()


def _index_log_path() -> String:
    return (
        _config_dir() + "/.index.log"
    )  # captured indexer output (a LOG, not KV)


def _pid_alive(pid: Int) -> Bool:
    """kill(pid, 0) liveness: 0 → the process exists; nonzero (ESRCH) → it's gone.
    The indexer is our own child so EPERM never applies — a clean 0 means alive.
    """
    if pid <= 0:
        return False
    return Int(external_call["kill", c_int](Int32(pid), c_int(0))) == 0


def _index_read_state_raw() -> String:
    """The state file verbatim (idle|indexing|done|error), no liveness reconciling.
    """
    try:
        return String(default_kv_store().get(KV_INDEX_STATE).strip())
    except:
        return String("idle")


def _read_runtotal() -> Int:
    """The current index run's total file count (stamped by the generator at enqueue),
    for the `[k/M]` progress bar. 0 when absent/unparsable."""
    try:
        return Int(String(default_kv_store().get(KV_INDEX_RUNTOTAL).strip()))
    except:
        return 0


def _write_runtotal(n: Int):
    _kv_set(KV_INDEX_RUNTOTAL, String(n))


def _wq_list_safe() -> List[WorkItem]:
    """`wq_list()` for non-raising callers (status/state derivation) — [] on any error.
    """
    try:
        return wq_list()
    except:
        return List[WorkItem]()


def _index_read_state() -> String:
    """Index state, DERIVED FROM THE WORK QUEUE. While any index-family item
    (prepare/index/finalize) is queued or running, an index run is in flight →
    `indexing`. Otherwise the settled outcome is the `.index.state` file the
    orchestrator writes on the finalize step (`done`/`error`), else `idle`. Orphaned
    runs are cleared by `_reconcile_stale`, so a dead run reads back settled — no
    phantom "running" row, no PID guard needed here anymore."""
    if index_active(_wq_list_safe()):
        return String("indexing")
    var raw = _index_read_state_raw()
    # A leftover "indexing" file (an older build, or a run whose items were
    # reconciled away) is NOT active per the queue → report idle, never a phantom row.
    if raw == "indexing":
        return String("idle")
    return raw^


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


def _pending_op_path() -> String:
    """Marker written when a detached index/reindex run STARTS (its type + start
    epoch), read back once the run settles to build the operation record. The full path
    is still used for the atomic-rename claim in `_finalize_index_op`."""
    return _config_dir() + "/" + KV_INDEX_OP


def _write_pending_op(kind: String, started: Int64):
    """Stamp the pending-operation marker for a just-launched index/reindex run.
    """
    _kv_set(
        KV_INDEX_OP,
        String('{"type":')
        + json_escape(kind)
        + ',"started":'
        + String(started)
        + "}",
    )


def _append_operation(
    kind: String,
    started: Int64,
    finished: Int64,
    status: String,
    detail: String,
    files: Int,
    txns: Int,
    tagged: Int,
):
    """Append ONE completed-operation record to operations.jsonl (best-effort; never
    raises). Negative counts are omitted (see `operation_record_line`)."""
    var line = operation_record_line(
        kind, started, finished, status, detail, files, txns, tagged
    )
    try:
        default_operations_store().append(
            line
        )  # +"\n" + chmod 0600, in the store
    except:
        log("[operations] append failed (non-fatal)")


def _indexed_file_count() -> Int:
    """Number of indexed FILE rows in manifest.tsv (mirrors handle_vault's parse).
    -1 when there's no manifest / a parse error — so the count is simply omitted.
    """
    var path = _config_dir() + "/manifest.tsv"
    if not isfile(path):
        return -1
    try:
        var text = default_manifest_store(_config_dir()).load(DOC_MANIFEST)
        var lines = text.split("\n")
        var n = 0
        for i in range(len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var cols = line.split("\t")
            if String(cols[0]) == "#meta":
                continue
            if (
                len(cols) < 7
            ):  # file row: alias name kind size sha id_start chunks
                continue
            n += 1
        return n
    except:
        return -1


def _stored_txn_count() -> Int:
    """Count of stored, reconciled transactions (-1 when unreadable → omitted).
    """
    try:
        return len(load_txn_rows())
    except:
        return -1


def _finalize_index_op():
    """If a detached index/reindex run has SETTLED (state done|error) and its pending
    marker is still present, record ONE operation for it and clear the marker. The
    marker is claimed with an atomic rename so that whichever caller (a status poll,
    a GET /api/operations, or the next run's start) wins records the run exactly
    once. Best-effort; never raises."""
    if not default_kv_store().exists(KV_INDEX_OP):
        return
    var state = _index_read_state()
    if state != "done" and state != "error":
        return  # still indexing / idle — nothing settled to record yet
    # Atomically claim the marker: the winner of the rename finalizes it.
    var claimed = _pending_op_path() + ".claiming"
    var op = _cstr(_pending_op_path())
    var cl = _cstr(claimed)
    var rc = external_call["rename", c_int](op, cl)
    op.free()
    cl.free()
    if Int(rc) != 0:
        return  # another caller already claimed it (or it vanished)
    var kind = String("index")
    var started = Int64(0)
    try:
        var text: String
        with open(claimed, "r") as f:
            text = f.read()
        var j = loads(text)
        kind = String(j["type"].string_value())
        started = j["started"].int_value()
    except:
        pass
    var finished = _epoch_s()
    # Belt-and-suspenders: a start epoch that's missing (<=0) or absurdly far in the
    # past (> 24h before finish) can't be THIS run's real start — it's a leaked stale
    # marker. Clamp it to `finished` so the stored record shows ~0s rather than a
    # bogus multi-hour duration (the client's fmtDur guards the display too).
    if started <= 0 or (finished - started) > Int64(86400):
        started = finished
    _append_operation(
        kind,
        started,
        finished,
        state,
        _index_progress(),
        _indexed_file_count(),
        _stored_txn_count(),
        -1,  # tagged: n/a for an index run
    )
    try:
        remove(claimed)
    except:
        pass


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
    # Route through the doc-store seam; keep `_write_small`'s best-effort swallow so a
    # failed registry write never wedges the caller (byte-identical to the prior write).
    try:
        default_indexed_paths_store().save(DOC_INDEXED_PATHS, out)
    except:
        pass


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


def _norm_roots(paths: List[String]) raises -> List[String]:
    """Drop trailing slashes (except a bare `/`) — mirrors `build_index`'s root
    normalization so the server computes the SAME source base the indexer would.
    """
    var out = List[String]()
    for i in range(len(paths)):
        var r = String(paths[i])
        while r.byte_length() > 1 and r.endswith("/"):
            r = String(r[byte = : r.byte_length() - 1])
        out.append(r^)
    return out^


def _start_index_run(
    paths: List[String], kind: String, record_op: Bool = True
) -> Bool:
    """The index generator (ORCHESTRATOR.md §2.1): instead of spawning a detached
    monolithic `millfolio index`, ENUMERATE the tracked-paths union into its candidate
    files and enqueue one `index` work item per file (dedup coalesces repeats), bracketed
    by a `index-prepare` first and a `finalize` last. The orchestrator loop then drains
    them ONE at a time, re-checking pause/priority + yielding to queries between files.

    Computes the source base + file set with the SAME helpers the indexer uses
    (`common_base`/`collect_index_paths`/`manifest_for_files`) so per-file names match.
    Stamps every path as tracked (`lastIndexed = now`), resets the run log, records the
    file total (for the `[k/M]` bar) and — when `record_op` — the pending-op marker
    (kind index|reindex). The sample-data import passes `record_op=False`: it drives the
    SAME per-file index run through the orchestrator (so it shows in Operations), but the
    whole download+index is recorded as ONE `demo` op instead of a separate `index` op.
    False when the run-script isn't configured or no paths were given."""
    var run_script = String(getenv("MILLFOLIO_RUN_SCRIPT", "").strip())
    if run_script == "" or len(paths) == 0:
        return False
    try:
        var nroots = _norm_roots(paths)
        var base = common_base(nroots)
        var infos = manifest_for_files(collect_index_paths(nroots))
        var files = List[String]()
        for i in range(len(infos)):
            files.append(infos[i].path.copy())

        # Record the tracked set (all indexed now) so a poll of /api/index/folders
        # right after start already reflects the new path.
        var now = _epoch_s()
        var epochs = List[String]()
        for _ in range(len(paths)):
            epochs.append(String(now))
        _write_tracked(paths, epochs)

        # Attribute any prior settled run before this one overwrites its markers, then
        # reset the run log, stamp the file total + this run's pending-op identity.
        _finalize_index_op()
        _write_small(_index_log_path(), "")
        _write_runtotal(len(files))
        # A stale pending marker from a never-finalized prior run would leak its
        # `started` into this run's finalize (the bogus-duration bug) — drop it first.
        try:
            if exists(_pending_op_path()):
                remove(_pending_op_path())
        except:
            pass
        if record_op:
            _write_pending_op(kind, now)

        # Enqueue prepare → per-file index → finalize (all at `now`; id order runs them
        # prepare-first, finalize-last). Dedup keeps a re-request from double-queuing.
        var plan = index_run_plan(base, files)
        for i in range(len(plan)):
            _ = wq_enqueue(plan[i].kind, plan[i].payload, now, plan[i].prio)
        return True
    except:
        return False
