"""handlers_operations — the Operations tab + general folder/file indexing.

The Vault/Files indexing surface + the durable operations history:
  • GET  /api/operations          — the durable history of COMPLETED runs (jsonl).
  • GET  /api/orchestrator/queue  — the work-queue contents (running + pending).
  • POST /api/index               — index an arbitrary local folder/file (tracked).
  • GET  /api/index/status        — the folder-index job's progress.
  • GET  /api/index/folders       — the tracked-folders registry.
  • POST /api/index/reindex       — re-run indexing to pick up new/changed files.
  • POST /api/index/folders/remove — stop tracking a folder.

The on-device indexer keys its store on the common-ancestor of the paths it's
handed and rebuilds when that base shifts, so index/reindex always run the UNION
of every tracked path (see handle_index). One job at a time; the actual index
steps run as subprocesses through the work orchestrator.

Phase-1B slice 2: pure moves of the `Api.handle_*` methods (and the inline
`/api/index/status` + `/api/orchestrator/queue` + `/api/index/folders` route
bodies, now free `handle_*` functions) plus the index/tracked-folders helper
cluster. None deref `self.st`; the `self`-qualified helper calls resolve to the
already-extracted leaf modules (`osutil`, `httputil`, `events`, `store`,
`vault.storage`, `work_orchestrator`, `scheduler`, `work_queue`, `handlers_demo`).
`work_orchestrator` never imports this module, and `handlers_demo` doesn't either,
so it stays acyclic. `server._route` now delegates here.

Five write-only/never-called path helpers (`_index_state_path`, `_index_pid_path`,
`_index_read_pid`, `_index_runtotal_path`, `_operations_path`) were dead in
server.mojo (no callers) and are dropped here rather than carried — no behaviour
change.
"""

from std.os import getenv
from std.os.path import exists

from flare.prelude import *

from json import loads

from vault.storage import (
    default_operations_store,
    default_indexed_paths_store,
    DOC_INDEXED_PATHS,
)
from work_orchestrator import (
    _finalize_index_op,
    _start_index_run,
    _write_tracked,
    _wq_list_safe,
    _read_runtotal,
    _index_read_state,
    _index_progress,
)
from scheduler import index_active, index_current, short_payload
from work_queue import wq_list
from record_builders import operations_records_array, parse_progress_counter

import handlers_demo
from osutil import _is_demo, _config_dir
from httputil import unauthorized, _cors
from events import json_escape


# ── HTTP handlers ────────────────────────────────────────────────────────────


def handle_operations() raises -> Response:
    """GET /api/operations → {"operations":[…]} — the durable history of COMPLETED
    index / reindex / backfill runs (operations.jsonl), newest-first and capped at
    the last 100. Same JSONL-comma-join pattern as /api/history (no server-side
    parse). Empty in the public demo (synthetic, read-only — nothing to index).
    """
    if _is_demo():
        return _cors(ok_json('{"operations":[]}'))
    _finalize_index_op()  # fold in a just-settled index run before serving
    handlers_demo._finalize_demo_op()  # …and a just-settled sample-data import
    var raw = String("")
    try:
        raw = default_operations_store().read_all()
    except:
        pass  # missing file → empty list
    return _cors(
        ok_json('{"operations":' + operations_records_array(raw, 100) + "}")
    )


def handle_orchestrator_queue() raises -> Response:
    """GET /api/orchestrator/queue → the work-queue contents (running + pending) so
    Operations can show what's queued behind the running job. Empty in the demo.
    """
    if _is_demo():
        return _cors(ok_json('{"items":[]}'))
    return _cors(ok_json(_orchestrator_queue_json()))


def handle_index_status() raises -> Response:
    """GET /api/index/status → the folder-index job's progress (records a just-settled
    run the moment it's seen)."""
    _finalize_index_op()  # record a just-settled run the moment it's seen
    return _cors(ok_json(_index_status_json()))


def handle_index_folders() raises -> Response:
    """GET /api/index/folders → the tracked-folders registry."""
    return _cors(ok_json(_tracked_folders_json()))


def handle_index(req: Request) raises -> Response:
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
        return _cors(bad_request('{"error":"an index job is already running"}'))
    # Union of the already-tracked paths + this one (dedup, order-preserving).
    var union = _read_tracked_paths()
    var seen = False
    for i in range(len(union)):
        if union[i] == p:
            seen = True
            break
    if not seen:
        union.append(p.copy())
    if not _start_index_run(union, "index"):
        return _cors(bad_request('{"error":"could not start indexing"}'))
    return _cors(ok_json('{"ok":true,"state":"indexing"}'))


def handle_index_reindex(req: Request) raises -> Response:
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
        return _cors(bad_request('{"error":"an index job is already running"}'))
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
                return _cors(bad_request('{"error":"path is not tracked"}'))
    except:
        pass  # no/empty body → re-index all tracked
    if not _start_index_run(tracked, "reindex"):
        return _cors(bad_request('{"error":"could not start indexing"}'))
    return _cors(ok_json('{"ok":true,"state":"indexing"}'))


def handle_index_folder_remove(req: Request) raises -> Response:
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


# ── general folder/file indexing (Vault/Files) ────────────────────────────────
# The SAME detached-job + state/log-file pattern as the sample-vault import,
# generalised to any local path, plus a small tracked-folders registry so a re-index
# can pick up new files. See `handle_index` for the append-not-clobber rationale.


def _tracked_paths_path() -> String:
    return _config_dir() + "/indexed-paths.json"  # the tracked-folders registry


def _orchestrator_queue_json() raises -> String:
    """GET /api/orchestrator/queue → {"items":[…]} — the work-queue contents (pending
    + running) so Operations can show what's queued behind the running job. Ordered
    running-first (the active job), then pending in run-order (priority, then FIFO —
    the order `wq_list` returns). Payloads are shortened to a basename/count so no
    absolute on-device path leaks. Read-only."""
    var items = wq_list()
    var out = String('{"items":[')
    var first = True
    # Two passes: running items first (the active job), then pending, each preserving
    # wq_list's priority/FIFO order.
    for pass_ix in range(2):
        var want_running = pass_ix == 0
        for i in range(len(items)):
            var is_running = items[i].state == "running"
            if is_running != want_running:
                continue
            if not first:
                out += ","
            first = False
            out += '{"id":' + String(items[i].id)
            out += ',"kind":' + json_escape(items[i].kind)
            out += ',"payload":' + json_escape(
                short_payload(items[i].kind, items[i].payload)
            )
            out += ',"prio":' + String(items[i].prio)
            out += ',"state":' + json_escape(items[i].state)
            out += ',"pid":' + String(items[i].pid)
            out += ',"startedTs":' + String(items[i].started_ts)
            out += "}"
    out += "]}"
    return out


def _index_running() -> Bool:
    """True while an index run is in flight — an index/prepare/finalize item is queued
    or running. The single source of truth for the "already running" guard and status.
    """
    return index_active(_wq_list_safe())


def _index_status_json() raises -> String:
    """{"state","detail"[,"current","total"]} for the folder-index job — same shape
    as the demo status. `state` is idle|indexing|done|error. When the progress line
    carries a `[n/M]` per-file counter (the embedding phase), `current`/`total` are
    included so the UI can show an "n of M files" bar; they're omitted otherwise
    (scanning phase, non-file lines, done/idle)."""
    var state = _index_read_state()
    var detail = _index_progress()
    var out = String('{"state":') + json_escape(state)
    out += ',"detail":' + json_escape(detail)
    # current/total = the queue-derived "n of M files": M is this run's file total
    # (stamped at enqueue); n = files started-or-done = M − pending index items.
    if state == "indexing":
        var total = _read_runtotal()
        if total > 0:
            out += ',"current":' + String(index_current(total, wq_list()))
            out += ',"total":' + String(total)
    else:
        # Settled: fall back to any [n/M] counter still in the last progress line.
        var counter = parse_progress_counter(detail)
        if counter[1] > 0:
            out += ',"current":' + String(counter[0])
            out += ',"total":' + String(counter[1])
    out += "}"
    return out


# ── tracked-folders registry ──────────────────────────────────────────────────
# A durable, append-only log of COMPLETED index/reindex/backfill runs lives in
# operations.jsonl (recorded lazily by the work orchestrator); the tracked-folders
# registry below is what index/reindex read to compute the union to re-embed.


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
    var text = default_indexed_paths_store().load(DOC_INDEXED_PATHS)
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
    """Just the tracked folder paths (convenience for the index/reindex handlers).
    """
    var t = _read_tracked()
    return t.paths.copy()


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
