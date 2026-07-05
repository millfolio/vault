"""Disk-backed **work queue** for the orchestrator (see `ORCHESTRATOR.md` §2.1–2.2).

Phase 1: a self-contained, testable queue of `WorkItem` records. It is **not yet
wired** into the live index/backfill paths — nothing imports it, so building it
cannot change any current behavior (the server binary doesn't pull this module).

Modeled on `runqueue.mojo`: the same `flock(LOCK_EX)` lock discipline (raw libc on a
sibling `.lock` file), file I/O by PATH, and an env-overridable path for tests
(`MILLFOLIO_WORKQ_PATH`). Where runqueue persists two ints, this persists a small
list of records plus a monotonic id counter.

**Persistence format** — a plain-text, line-per-record file at `work_queue_path()`
(`_config_dir()/work_queue.jsonl`, override `MILLFOLIO_WORKQ_PATH`):

    #nextid\t<N>                                              ← header: next id to hand out
    <id>\t<kind>\t<payload>\t<enq_at>\t<prio>\t<state>\t<pid>\t<started_ts>
    ...

TSV (one record per line), matching runqueue's plain-text choice over JSON. The
`kind`/`payload`/`state` string fields are escaped (`\\`, `\t`, `\n`) so a payload
can never inject a field/line break. A torn or otherwise unparseable line is
**skipped**, not fatal (mirrors the operations-log resilience). Writes are atomic:
serialize the whole state to `<path>.tmp`, then `rename()` over the real file.

**Id scheme** — the header's `#nextid` is authoritative and persists across restart,
so ids stay strictly monotonic **even after the queue fully drains** (a bare
max-of-existing+1 rule would recycle ids once empty). On load we still defensively
bump `next_id` past any existing id, so a corrupt/missing header can't reissue a
live id.

Unit-tested by `test/work_queue_test.mojo` (task `pixi run test-workqueue`).
"""
from std.ffi import external_call, c_char
from std.memory import alloc
from std.os import getenv
from flare.prelude import *  # MutUntrackedOrigin

comptime _O_RDWR: Int = 0x0002
comptime _O_CREAT: Int = 0x0200
comptime _LOCK_EX: Int = 0x0002
comptime _LOCK_UN: Int = 0x0008

# Class priorities by kind (lower number = higher priority). Callers pass these in
# — the queue only orders by the number; these are documented defaults.
comptime PRIO_INDEX: Int = 10
comptime PRIO_FINALIZE: Int = 10
comptime PRIO_BACKFILL: Int = 20


@fieldwise_init
struct WorkItem(Copyable, Movable):
    """One unit of background engine work. `payload` is opaque to the queue."""

    var id: Int  # monotonic, assigned on enqueue; stable across restart
    var kind: String  # "index" | "finalize" | "backfill"
    var payload: String  # index: file path/alias; finalize: run id; backfill: scope
    var enq_at: Int64  # epoch seconds, supplied by the caller (queue never reads time)
    var prio: Int  # lower = higher priority
    var state: String  # "pending" | "running"
    var pid: Int  # running worker pid (0 while pending)
    var started_ts: Int64  # epoch seconds the run started (0 while pending)


@fieldwise_init
struct QueueState(Copyable, Movable):
    """In-memory snapshot of the queue file: the items + the next id to hand out.
    """

    var items: List[WorkItem]
    var next_id: Int


# ── Path + libc lock/rename plumbing (mirrors runqueue.mojo) ───────────────────


def _wq_config_dir() -> String:
    """The on-device DATA dir — matches server `_config_dir()` /
    vault/core `store.config_dir()`; overridable via `MILLFOLIO_DATA_DIR`."""
    var d = String(getenv("MILLFOLIO_DATA_DIR", ""))
    if String(d.strip()).byte_length() > 0:
        return String(d.strip())
    return (
        String(getenv("HOME", "."))
        + "/Library/Application Support/Millfolio/data"
    )


def work_queue_path() -> String:
    """The queue state file. `MILLFOLIO_WORKQ_PATH` overrides it (tests use that).
    """
    var override = String(getenv("MILLFOLIO_WORKQ_PATH", ""))
    if override.byte_length() > 0:
        return override
    return _wq_config_dir() + "/work_queue.jsonl"


def _cstr(s: String) -> UnsafePointer[c_char, MutUntrackedOrigin]:
    var n = s.byte_length()
    var p = alloc[c_char](n + 1)
    var sp = s.unsafe_ptr()
    for i in range(n):
        (p + i).init_pointee_copy(c_char(Int(sp[i])))
    (p + n).init_pointee_copy(c_char(0))
    return p


def _lock() -> Int32:
    var cpath = _cstr(work_queue_path() + ".lock")
    var fd = external_call["open", Int32](
        cpath, Int32(_O_RDWR | _O_CREAT), Int32(0o600)
    )
    cpath.free()
    if fd >= Int32(0):
        _ = external_call["flock", Int32](fd, Int32(_LOCK_EX))
    return fd


def _unlock(fd: Int32):
    if fd >= Int32(0):
        _ = external_call["flock", Int32](fd, Int32(_LOCK_UN))
        _ = external_call["close", Int32](fd)


def _rename(src: String, dst: String):
    var s = _cstr(src)
    var d = _cstr(dst)
    _ = external_call["rename", Int32](s, d)
    s.free()
    d.free()


# ── (De)serialization ─────────────────────────────────────────────────────────


def _escape(s: String) -> String:
    """Make a string field safe to embed between tabs / on one line."""
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def _unescape(s: String) -> String:
    var out = String("")
    var esc = False
    for cp in s.codepoint_slices():
        if esc:
            var c = String(cp)
            if c == "t":
                out += "\t"
            elif c == "n":
                out += "\n"
            elif c == "\\":
                out += "\\"
            else:
                out += "\\" + c  # unknown escape — keep it literal
            esc = False
        elif String(cp) == "\\":
            esc = True
        else:
            out += String(cp)
    if esc:
        out += "\\"  # trailing lone backslash
    return out


def _parse_int(s: String) -> Tuple[Int, Bool]:
    """Parse a (possibly negative) base-10 int; second element is False if invalid.
    """
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        return (0, False)
    var i = 0
    var neg = False
    if Int(b[0]) == 45:  # '-'
        neg = True
        i = 1
    var val = 0
    var any_digit = False
    while i < n:
        var c = Int(b[i])
        if c < 48 or c > 57:
            return (0, False)
        val = val * 10 + (c - 48)
        any_digit = True
        i += 1
    if not any_digit:
        return (0, False)
    if neg:
        val = -val
    return (val, True)


def _serialize_item(it: WorkItem) -> String:
    return (
        String(it.id)
        + "\t"
        + _escape(it.kind)
        + "\t"
        + _escape(it.payload)
        + "\t"
        + String(it.enq_at)
        + "\t"
        + String(it.prio)
        + "\t"
        + _escape(it.state)
        + "\t"
        + String(it.pid)
        + "\t"
        + String(it.started_ts)
    )


def _parse_item(line: String) raises -> Tuple[WorkItem, Bool]:
    var parts = line.split("\t")
    if len(parts) != 8:
        return (WorkItem(0, "", "", 0, 0, "", 0, 0), False)
    var rid = _parse_int(String(parts[0]))
    var renq = _parse_int(String(parts[3]))
    var rprio = _parse_int(String(parts[4]))
    var rpid = _parse_int(String(parts[6]))
    var rts = _parse_int(String(parts[7]))
    if not (rid[1] and renq[1] and rprio[1] and rpid[1] and rts[1]):
        return (WorkItem(0, "", "", 0, 0, "", 0, 0), False)
    var it = WorkItem(
        rid[0],
        _unescape(String(parts[1])),
        _unescape(String(parts[2])),
        Int64(renq[0]),
        rprio[0],
        _unescape(String(parts[5])),
        rpid[0],
        Int64(rts[0]),
    )
    return (it^, True)


# ── Load / save (caller holds the lock) ───────────────────────────────────────


def _load() raises -> QueueState:
    """Read the whole queue file; skip torn/garbage lines; ensure a monotonic id.
    """
    var items = List[WorkItem]()
    var next_id = 1
    var have_header = False
    try:
        var content: String
        with open(work_queue_path(), "r") as f:
            content = f.read()
        for line_slice in content.split("\n"):
            var line = String(line_slice)
            if line.byte_length() == 0:
                continue
            if line.startswith("#nextid"):
                var hparts = line.split("\t")
                if len(hparts) >= 2:
                    var r = _parse_int(String(hparts[1]))
                    if r[1]:
                        next_id = r[0]
                        have_header = True
                continue
            var parsed = _parse_item(line)
            if parsed[1]:
                items.append(parsed[0].copy())
    except:
        pass  # missing/unreadable file → empty queue
    # Defensively keep ids strictly monotonic even if the header was lost/corrupt.
    var maxid = 0
    for i in range(len(items)):
        if items[i].id > maxid:
            maxid = items[i].id
    if not have_header or next_id <= maxid:
        next_id = maxid + 1
    if next_id < 1:
        next_id = 1
    return QueueState(items^, next_id)


def _save(state: QueueState):
    """Atomically persist: write the full state to `<path>.tmp`, then rename over.
    """
    var content = String("#nextid\t") + String(state.next_id) + "\n"
    for i in range(len(state.items)):
        content += _serialize_item(state.items[i]) + "\n"
    var tmp = work_queue_path() + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(content)
        _rename(tmp, work_queue_path())
    except:
        pass  # best-effort, like runqueue's write


# ── Ordering ──────────────────────────────────────────────────────────────────


def _less(a: WorkItem, b: WorkItem) -> Bool:
    """True if `a` should run before `b`: lower prio, then earlier enq_at, then id.
    """
    if a.prio != b.prio:
        return a.prio < b.prio
    if a.enq_at != b.enq_at:
        return a.enq_at < b.enq_at
    return a.id < b.id


# ── Public API (each takes the lock, load-modify-saves, like runq_*) ───────────


def wq_enqueue(
    kind: String, payload: String, enq_at: Int64, prio: Int
) raises -> Int:
    """Append a pending item and return its id. Dedup: an identical (kind, payload)
    already pending or running coalesces — return the existing id, add nothing.
    """
    var lk = _lock()
    var state = _load()
    for i in range(len(state.items)):
        if (
            state.items[i].kind == kind
            and state.items[i].payload == payload
            and (
                state.items[i].state == "pending"
                or state.items[i].state == "running"
            )
        ):
            var existing = state.items[i].id
            _unlock(lk)
            return existing
    var id = state.next_id
    state.next_id += 1
    state.items.append(
        WorkItem(id, kind, payload, enq_at, prio, "pending", 0, 0)
    )
    _save(state)
    _unlock(lk)
    return id


def wq_peek() raises -> Optional[WorkItem]:
    """The highest-priority pending item (lowest prio, then enq_at, then id)."""
    var lk = _lock()
    var state = _load()
    _unlock(lk)
    var best = -1
    for i in range(len(state.items)):
        if state.items[i].state != "pending":
            continue
        if best < 0 or _less(state.items[i], state.items[best]):
            best = i
    if best < 0:
        return None
    return Optional[WorkItem](state.items[best].copy())


def wq_take(id: Int, pid: Int, started_ts: Int64) raises -> Bool:
    """Mark a pending item running with its pid + start ts. False if not pending.
    """
    var lk = _lock()
    var state = _load()
    var ok = False
    for i in range(len(state.items)):
        if state.items[i].id == id and state.items[i].state == "pending":
            state.items[i].state = "running"
            state.items[i].pid = pid
            state.items[i].started_ts = started_ts
            ok = True
            break
    if ok:
        _save(state)
    _unlock(lk)
    return ok


def _remove(id: Int) raises -> Bool:
    var lk = _lock()
    var state = _load()
    var found = False
    var kept = List[WorkItem]()
    for i in range(len(state.items)):
        if state.items[i].id == id:
            found = True
        else:
            kept.append(state.items[i].copy())
    if found:
        state.items = kept^
        _save(state)
    _unlock(lk)
    return found


def wq_done(id: Int) raises -> Bool:
    """Remove a completed item. Returns whether it existed."""
    return _remove(id)


def wq_fail(id: Int, reason: String) raises -> Bool:
    """Drop a failed item (Phase 1: no retry — just remove). Returns whether it
    existed. `reason` is accepted for API stability; a later phase records it.
    """
    return _remove(id)


def wq_list() raises -> List[WorkItem]:
    """All items (pending + running) in priority order — for the UI/status."""
    var lk = _lock()
    var state = _load()
    _unlock(lk)
    var out = List[WorkItem]()
    for i in range(len(state.items)):
        out.append(state.items[i].copy())
    # selection sort by _less (queues are small — O(n^2) is fine)
    for i in range(len(out)):
        var m = i
        for j in range(i + 1, len(out)):
            if _less(out[j], out[m]):
                m = j
        if m != i:
            var tmp = out[i].copy()
            out[i] = out[m].copy()
            out[m] = tmp^
    return out^


def wq_running() raises -> Optional[WorkItem]:
    """The currently-running item, if any (at most one; returns the first)."""
    var lk = _lock()
    var state = _load()
    _unlock(lk)
    for i in range(len(state.items)):
        if state.items[i].state == "running":
            return Optional[WorkItem](state.items[i].copy())
    return None


def wq_reset():
    """Clear the queue (tests + a hard reset): empty items, id counter back to 1.
    """
    var lk = _lock()
    _save(QueueState(List[WorkItem](), 1))
    _unlock(lk)
