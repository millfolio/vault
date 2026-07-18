"""Disk-backed **work queue** for the scheduler (see `SCHEDULER.md` §2.1–2.2).

This module is now a **thin facade over the storage seam** (`vault.storage`, promoted
to `vault/core` in Phase 2 slice B1 — see `STORAGE.md`). It keeps the public `wq_*` API
stable — `scheduler.mojo`, `server.mojo`, and `test/work_queue_test.mojo` import from
here unchanged — but the actual queue of `WorkItem` records now lives behind the
`QueueStore` trait, implemented by `FileQueueStore` (the byte-identical flock +
tmp-rename JSONL persistence, moved verbatim into `vault.storage`). Each `wq_*` function
is a one-liner that constructs the
`default_queue_store()` (a `FileQueueStore` over `work_queue_path()`, re-reading
`MILLFOLIO_WORKQ_PATH` every call) and delegates the operation to it.

Splitting the persistence out of the API is Phase 2 slice 1 of the backend storage
cleanup: the queue is the first data category to move behind `Store` traits so its
on-disk format is swappable (TSV/JSONL now → SQLite later) without touching the
~call sites. The `WorkItem`/`QueueState` records, the `PRIO_*` class defaults, the
`work_queue_path()` helper, and the on-disk format are all defined in `vault.storage`
and re-exported here so existing `from work_queue import …` sites keep resolving.

Unit-tested by `test/work_queue_test.mojo` (task `pixi run test-workqueue`) — the same
suite as before, unchanged, since behavior is identical.
"""
from vault.storage import (
    WorkItem,
    QueueState,
    QueueStore,
    FileQueueStore,
    default_queue_store,
    work_queue_path,
    PRIO_INDEX,
    PRIO_FINALIZE,
    PRIO_BACKFILL,
)


def wq_enqueue(
    kind: String, payload: String, enq_at: Int64, prio: Int
) raises -> Int:
    """Append a pending item and return its id. Dedup: an identical (kind, payload)
    already pending or running coalesces — return the existing id, add nothing.
    """
    return default_queue_store().enqueue(kind, payload, enq_at, prio)


def wq_peek() raises -> Optional[WorkItem]:
    """The highest-priority pending item (lowest prio, then enq_at, then id)."""
    return default_queue_store().peek()


def wq_take(id: Int, pid: Int, started_ts: Int64) raises -> Bool:
    """Mark a pending item running with its pid + start ts. False if not pending.
    """
    return default_queue_store().take(id, pid, started_ts)


def wq_done(id: Int) raises -> Bool:
    """Remove a completed item. Returns whether it existed."""
    return default_queue_store().done(id)


def wq_fail(id: Int, reason: String) raises -> Bool:
    """Drop a failed item (Phase 1: no retry — just remove). Returns whether it
    existed. `reason` is accepted for API stability; a later phase records it.
    """
    return default_queue_store().fail(id, reason)


def wq_list() raises -> List[WorkItem]:
    """All items (pending + running) in priority order — for the UI/status."""
    return default_queue_store().list()


def wq_running() raises -> Optional[WorkItem]:
    """The currently-running item, if any (at most one; returns the first)."""
    return default_queue_store().running()


def wq_reset():
    """Clear the queue (tests + a hard reset): empty items, id counter back to 1.
    """
    default_queue_store().reset()
