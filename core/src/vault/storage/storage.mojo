"""Storage seam — the swappable persistence layer for millfolio's on-disk state.

This is the backend storage cleanup (see `app/server/STORAGE.md`): each data category
moves behind a trait so the on-disk format is swappable (TSV/JSONL today → SQLite
later) without touching the ~call sites. It follows the same pattern flare already uses
for its response cache (`flare/http/cache/store.mojo`: a `CacheStore` trait + an
in-memory impl, a filesystem impl slotting in behind the same trait).

**Module home (Phase 2 slice B1).** This lives in `vault/core` as the `vault.storage`
sub-package (import `from vault.storage import …`) so BOTH the app server AND the
vault-side registries can share one `Store` layer + one future `SqliteStore` backend.
It is NOT part of the `from vault import *` tool surface — it's internal infra, only
importable by name. To stay **acyclic** it depends on nothing but stdlib + the `flare`
sibling lib (already on vault's include path); it imports NOTHING from `app/server`.
The config-dir resolver (`_storage_config_dir`, formerly the server's `osutil._config_dir`)
and the owner-only `_chmod` (formerly `osutil._chmod`) are inlined here — both are tiny,
self-contained (env + a libc `chmod`), and duplicating them keeps `vault.storage` free of
any app/server import while reproducing the exact on-disk paths + file modes byte-for-byte.

**Slice 1 — the orchestrator work queue** (`QueueStore` / `FileQueueStore`). The
`WorkItem`/`QueueState` records, the `PRIO_*` class defaults, the path helper
(`work_queue_path`, honoring `MILLFOLIO_WORKQ_PATH`), and the byte-for-byte JSONL
persistence all live here; `work_queue.mojo` is a thin facade that re-exports them and
keeps the `wq_*` free functions as delegators to a `FileQueueStore`, so
`scheduler.mojo` / `server.mojo` / `test/work_queue_test.mojo` are UNCHANGED and
behavior is identical.

**Slice 2 — the append-logs** (`LogStore` / `FileLogStore`, at the bottom of this
file). The three append-only JSONL logs — `operations.jsonl`, `stats.jsonl`,
`asks.jsonl` — move behind one tiny trait: `append` a built record line, `read_all`
the raw file, `rewrite` the whole file. The pure record BUILDERS stay in `store.mojo`
(they assemble/parse the JSON); the store only moves bytes. `server.mojo`'s
`_append_*` / read handlers are the thin facade, unchanged in behavior. (The pending-op
KV markers `.index.op` / `.demo.op` that `operations.jsonl` pairs with are a LATER
kv slice — NOT migrated here.)

**Slice 3 — the KV / small-marker store** (`KvStore` / `FileKvStore`, at the bottom of
this file). The tiny single-value marker dotfiles — `.index.state` / `.index.pid` /
`.index.op` / `.index.runtotal` / `.demo.state` / `.demo.op` / `.model_download.state` /
`.model_download.model` — move behind one trait: `get` (raises on missing, like the
inline `open`), `set` (write whole), `delete`, `exists`. A `key` is the marker's logical
name (its basename); `FileKvStore` maps it to `<dir>/<key>`. `server.mojo`'s
`_kv_set` + the marker path helpers are the thin facade. This picks up the pending-op
markers `.index.op` / `.demo.op` the log slice deferred. The auth 0600 secrets and the
`sysmetrics` shell-redirect scratch caches are deliberately NOT migrated (see STORAGE.md
§4b).

**Contract — `QueueStore`.** enqueue / peek / take / done / fail / list / running /
reset over `WorkItem`. `FileQueueStore` implements it with the existing flock +
tmp-rename JSONL logic.

**On-disk format (unchanged).** A plain-text, line-per-record file at the store's
`path` (default `_wq_config_dir()/work_queue.jsonl`, override `MILLFOLIO_WORKQ_PATH`):

    #nextid\t<N>                                              ← header: next id to hand out
    <id>\t<kind>\t<payload>\t<enq_at>\t<prio>\t<state>\t<pid>\t<started_ts>
    ...

TSV, one record per line; the `kind`/`payload`/`state` string fields are escaped
(`\\`, `\t`, `\n`) so a payload can never inject a field/line break. A torn or
unparseable line is **skipped**, not fatal. Writes are atomic: serialize the whole
state to `<path>.tmp`, then `rename()` over the real file.

**Id scheme.** The header's `#nextid` is authoritative and persists across restart,
so ids stay strictly monotonic even after the queue fully drains. On load we still
defensively bump `next_id` past any existing id, so a corrupt/missing header can't
reissue a live id.

**Phase 5 swap.** A `SqliteQueueStore(QueueStore, …)` will conform to the SAME trait;
the swap point is `default_queue_store()` below (and, for a runtime config flag, a
`Variant[FileQueueStore, SqliteQueueStore]` dispatched in the delegators). SQLite
needs a Mojo `libsqlite3` FFI binding that doesn't exist yet — out of scope here.
"""
from std.ffi import external_call, c_char, c_int
from std.memory import alloc
from std.os import getenv, remove
from std.os.path import exists
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


# ── Path helpers ───────────────────────────────────────────────────────────────


def _storage_config_dir() -> String:
    """The on-device DATA dir every store resolves paths under — matches the server's
    `osutil._config_dir()` / vault/core `derive.tags.config_dir()`, overridable via
    `MILLFOLIO_DATA_DIR`. Inlined here (not imported from app/server) so `vault.storage`
    stays acyclic; reproduces the same path byte-for-byte."""
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
    return _storage_config_dir() + "/work_queue.jsonl"


# ── libc lock/rename plumbing (pure — take their paths as args) ────────────────


def _cstr(s: String) -> UnsafePointer[c_char, MutUntrackedOrigin]:
    var n = s.byte_length()
    var p = alloc[c_char](n + 1)
    var sp = s.unsafe_ptr()
    for i in range(n):
        (p + i).init_pointee_copy(c_char(Int(sp[i])))
    (p + n).init_pointee_copy(c_char(0))
    return p


def _chmod(path: String, mode: Int):
    """Best-effort `chmod(path, mode)` via libc — inlined from `osutil._chmod` so
    `vault.storage` stays acyclic. `open(...)` creates with the process umask; the JSONL
    stores hold personal financial data, so `FileLogStore.append` tightens them to
    owner-only (0600) after write, exactly as the server did."""
    var cp = _cstr(path)
    _ = external_call["chmod", c_int](cp, c_int(mode))
    cp.free()


def _lock_path(lock_path: String) -> Int32:
    var cpath = _cstr(lock_path)
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


# ── (De)serialization (pure) ───────────────────────────────────────────────────


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


def _less(a: WorkItem, b: WorkItem) -> Bool:
    """True if `a` should run before `b`: lower prio, then earlier enq_at, then id.
    """
    if a.prio != b.prio:
        return a.prio < b.prio
    if a.enq_at != b.enq_at:
        return a.enq_at < b.enq_at
    return a.id < b.id


# ── The storage contract + the file-backed implementation ──────────────────────


trait QueueStore(Copyable, Movable):
    """Persistence interface for the orchestrator work queue.

    A store owns the queue of `WorkItem` records and the id counter; the
    orchestrator (`server.mojo`) drives it through the `wq_*` delegators. Each
    mutating op is load-modify-save under the store's own lock, so the file is safe
    across the server + `mill` CLI + a detached index worker. The trait is
    intentionally small (enqueue/peek/take/done/fail/list/running/reset) so a second
    impl (Phase 5 `SqliteQueueStore`) can slot in behind it with a one-line swap.
    """

    def enqueue(
        self, kind: String, payload: String, enq_at: Int64, prio: Int
    ) raises -> Int:
        ...

    def peek(self) raises -> Optional[WorkItem]:
        ...

    def take(self, id: Int, pid: Int, started_ts: Int64) raises -> Bool:
        ...

    def done(self, id: Int) raises -> Bool:
        ...

    def fail(self, id: Int, reason: String) raises -> Bool:
        ...

    def list(self) raises -> List[WorkItem]:
        ...

    def running(self) raises -> Optional[WorkItem]:
        ...

    def reset(self):
        ...


@fieldwise_init
struct FileQueueStore(Copyable, Movable, QueueStore):
    """The JSONL-file queue store: the flock + tmp-rename persistence, unchanged.

    Holds only the state-file `path`; the lock (`<path>.lock`) and tmp
    (`<path>.tmp`) siblings are derived. The `wq_*` delegators construct one fresh
    per call around `work_queue_path()`, so `MILLFOLIO_WORKQ_PATH` is re-read every
    operation exactly as before.
    """

    var path: String

    # ── load / save (caller holds the lock) ────────────────────────────────────

    def _load(self) raises -> QueueState:
        """Read the whole queue file; skip torn/garbage lines; ensure monotonic id.
        """
        var items = List[WorkItem]()
        var next_id = 1
        var have_header = False
        try:
            var content: String
            with open(self.path, "r") as f:
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
        # Defensively keep ids strictly monotonic even if the header was lost.
        var maxid = 0
        for i in range(len(items)):
            if items[i].id > maxid:
                maxid = items[i].id
        if not have_header or next_id <= maxid:
            next_id = maxid + 1
        if next_id < 1:
            next_id = 1
        return QueueState(items^, next_id)

    def _save(self, state: QueueState):
        """Atomically persist: write the full state to `<path>.tmp`, then rename.
        """
        var content = String("#nextid\t") + String(state.next_id) + "\n"
        for i in range(len(state.items)):
            content += _serialize_item(state.items[i]) + "\n"
        var tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                f.write(content)
            _rename(tmp, self.path)
        except:
            pass  # best-effort, like runqueue's write

    def _lock(self) -> Int32:
        return _lock_path(self.path + ".lock")

    # ── public API (each takes the lock, load-modify-saves) ─────────────────────

    def enqueue(
        self, kind: String, payload: String, enq_at: Int64, prio: Int
    ) raises -> Int:
        """Append a pending item and return its id. Dedup: an identical (kind,
        payload) already pending or running coalesces — return the existing id.
        """
        var lk = self._lock()
        var state = self._load()
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
        self._save(state)
        _unlock(lk)
        return id

    def peek(self) raises -> Optional[WorkItem]:
        """The highest-priority pending item (lowest prio, then enq_at, then id).
        """
        var lk = self._lock()
        var state = self._load()
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

    def take(self, id: Int, pid: Int, started_ts: Int64) raises -> Bool:
        """Mark a pending item running with its pid + start ts. False if not pending.
        """
        var lk = self._lock()
        var state = self._load()
        var ok = False
        for i in range(len(state.items)):
            if state.items[i].id == id and state.items[i].state == "pending":
                state.items[i].state = "running"
                state.items[i].pid = pid
                state.items[i].started_ts = started_ts
                ok = True
                break
        if ok:
            self._save(state)
        _unlock(lk)
        return ok

    def _remove(self, id: Int) raises -> Bool:
        var lk = self._lock()
        var state = self._load()
        var found = False
        var kept = List[WorkItem]()
        for i in range(len(state.items)):
            if state.items[i].id == id:
                found = True
            else:
                kept.append(state.items[i].copy())
        if found:
            state.items = kept^
            self._save(state)
        _unlock(lk)
        return found

    def done(self, id: Int) raises -> Bool:
        """Remove a completed item. Returns whether it existed."""
        return self._remove(id)

    def fail(self, id: Int, reason: String) raises -> Bool:
        """Drop a failed item (Phase 1: no retry — just remove). Returns whether it
        existed. `reason` is accepted for API stability; a later phase records it.
        """
        return self._remove(id)

    def list(self) raises -> List[WorkItem]:
        """All items (pending + running) in priority order — for the UI/status.
        """
        var lk = self._lock()
        var state = self._load()
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

    def running(self) raises -> Optional[WorkItem]:
        """The currently-running item, if any (at most one; returns the first).
        """
        var lk = self._lock()
        var state = self._load()
        _unlock(lk)
        for i in range(len(state.items)):
            if state.items[i].state == "running":
                return Optional[WorkItem](state.items[i].copy())
        return None

    def reset(self):
        """Clear the queue (tests + a hard reset): empty items, id counter back to 1.
        """
        var lk = self._lock()
        self._save(QueueState(List[WorkItem](), 1))
        _unlock(lk)


def default_queue_store() -> FileQueueStore:
    """The queue store the `wq_*` delegators use — the single swap point. Today it's
    the file-backed store over `work_queue_path()`; Phase 5 changes this line (and,
    for a runtime flag, returns a `Variant[FileQueueStore, SqliteQueueStore]`).
    """
    return FileQueueStore(work_queue_path())


# ── Slice 2: append-log stores (operations.jsonl · stats.jsonl · asks.jsonl) ────
# The three append-only JSONL logs behind one `LogStore` trait, mirroring the queue
# slice. Each log is an owner-only file of one JSON object per line. The pure record
# BUILDERS stay in `store.mojo` (they assemble/parse the JSON) — the store only
# PERSISTS a built line and hands back the RAW file so the builders
# (`history_records_array` / `operations_records_array`, and stats' inline
# comma-join) do their newest-first / cap / torn-line-skip over it UNCHANGED. So the
# read method returns the raw file text and RAISES on a missing file exactly like the
# `open(...)` it replaces — each caller keeps its own `try/except → empty` — rather
# than a pre-split, pre-skipped list that would relocate the builders' logic and risk
# drifting from the byte-identical HTTP output.


def operations_log_path() -> String:
    """operations.jsonl — completed index/reindex/backfill runs. `MILLFOLIO_OPS_FILE`
    overrides; else beside the other logs under the data dir."""
    return String(
        getenv(
            "MILLFOLIO_OPS_FILE", _storage_config_dir() + "/operations.jsonl"
        )
    )


def stats_log_path() -> String:
    """stats.jsonl — per-question usage records. `MILLFOLIO_STATS_FILE` overrides.
    """
    return String(
        getenv("MILLFOLIO_STATS_FILE", _storage_config_dir() + "/stats.jsonl")
    )


def asks_log_path() -> String:
    """asks.jsonl — full per-ask history (question + generated program + answer).
    `MILLFOLIO_ASKS_FILE` overrides."""
    return String(
        getenv("MILLFOLIO_ASKS_FILE", _storage_config_dir() + "/asks.jsonl")
    )


trait LogStore(Copyable, Movable):
    """Persistence interface for an append-only JSONL event log.

    Three logs share it (operations / stats / asks). The contract is deliberately
    tiny — `append` one already-built record, `read_all` the raw file, `rewrite` the
    whole file (the asks delete-record compaction). Record ASSEMBLY/PARSING is NOT
    here: it stays in the pure builders (`store.mojo`); the store only moves bytes. A
    Phase 5 `SqliteLogStore` conforms to the SAME trait (an append-only table with a
    rowid clock; `read_all` reconstructs the same newline-joined text so the builders
    keep working unchanged), swapped in at the `default_*_store()` factories below.
    """

    def append(self, record: String) raises:
        ...

    def read_all(self) raises -> String:
        ...

    def rewrite(self, content: String) raises:
        ...


@fieldwise_init
struct FileLogStore(Copyable, LogStore, Movable):
    """The file-backed append log: the existing `open`/`f.write`/`_chmod` logic moved
    verbatim behind the trait. Holds only the log's `path`; one instance per log, so a
    fresh one is built per call around the log's path helper (re-reading the
    `MILLFOLIO_*_FILE` override every op, like the queue store).

    `append` writes `record + "\\n"` (one JSONL line) then tightens the file to
    owner-only (0600) — the same two calls every `_append_*` did. `read_all` opens the
    file for read and returns its whole contents, RAISING on a missing/unreadable file
    exactly as the previous `with open(path, "r")` did, so each caller keeps its own
    `try/except → empty`. `rewrite` truncates + writes the whole file (no chmod, as
    before — the "w" open preserves the existing owner-only mode) for the ask-history
    delete compaction.
    """

    var path: String

    def append(self, record: String) raises:
        with open(self.path, "a") as f:
            f.write(record + "\n")  # JSONL — one record per line
        _chmod(self.path, 0o600)  # owner-only: holds personal financial data

    def read_all(self) raises -> String:
        var content: String
        with open(self.path, "r") as f:
            content = f.read()
        return content

    def rewrite(self, content: String) raises:
        with open(self.path, "w") as f:
            f.write(content)


def default_operations_store() -> FileLogStore:
    """The operations-log store — a swap point for Phase 5 (`operations.jsonl`).
    """
    return FileLogStore(operations_log_path())


def default_stats_store() -> FileLogStore:
    """The stats-log store — a swap point for Phase 5 (`stats.jsonl`)."""
    return FileLogStore(stats_log_path())


def default_asks_store() -> FileLogStore:
    """The ask-history store — a swap point for Phase 5 (`asks.jsonl`)."""
    return FileLogStore(asks_log_path())


# ── Slice 3: KV / small-marker store (single-value dotfiles) ───────────────────
# The tiny single-value marker files behind one `KvStore` trait, mirroring the queue +
# log slices. Each marker is a bare text file read/written WHOLE — a state word, a pid,
# a run-total count, a pending-op JSON blob. A `key` is the marker's LOGICAL name (its
# on-disk basename, e.g. `.index.state`), NOT a filesystem path: `FileKvStore` maps
# `key → <dir>/<key>`, so a Phase-5 `SqliteKvStore` can reuse the SAME keys as the
# primary key of one `kv(k TEXT PRIMARY KEY, v BLOB)` table with no call-site change.
#
# The eight migrated markers — all written/read WHOLE by the server IN-PROCESS (via
# `_write_small` / inline `open`). Their logical key names double as the on-disk
# basenames, so `FileKvStore(_config_dir())` reproduces the old `_config_dir()+"/.<name>"`
# path byte-for-byte:
comptime KV_INDEX_STATE = ".index.state"  # idle|indexing|done|error
comptime KV_INDEX_PID = ".index.pid"  # detached index worker's PID
comptime KV_INDEX_OP = (  # pending index/reindex op marker (lazy-finalize)
    ".index.op"
)
comptime KV_INDEX_RUNTOTAL = ".index.runtotal"  # file count for the current run
comptime KV_DEMO_STATE = ".demo.state"  # downloading|indexing|done|error
comptime KV_DEMO_OP = (  # pending sample-data import marker (lazy-finalize)
    ".demo.op"
)
comptime KV_DL_STATE = ".model_download.state"  # running|done|error
comptime KV_DL_MODEL = ".model_download.model"  # the in-flight model id
#
# NOT migrated (deliberate): the auth secrets `.anthropic-key` / `.reveal-secret` keep
# their `chmod 0600` semantics + own tests in `auth.mojo` (a plain KV set would widen the
# mode); the captured-output LOGS `.index.log` / `.demo.log` / `.model_download.log` are
# append+last-line-read streams, not single-value markers; and the scratch caches
# `.gpu_util` / `.mem_bytes` / `.mem_used` / `.disk_used` / `.dl_du` are WRITTEN BY A SHELL
# REDIRECT (`… > '<path>'`) inside a `system()` subprocess — only their read is Mojo — so
# they can't route through a Mojo `set` (and couldn't back onto SQLite); they stay put in
# `sysmetrics.mojo` / `_du_bytes`. See STORAGE.md §4b.


trait KvStore(Copyable, Movable):
    """Persistence interface for the small single-value markers.

    A `key` is a marker's logical name; the store maps it to storage. The contract is
    tiny — `get` returns the WHOLE stored value and RAISES on a missing key exactly like
    the `with open(path, "r")` each marker read replaces (so every caller keeps its own
    `try/except → default` + `.strip()`); `set` writes the value WHOLE (last-write-wins);
    `delete` removes it (raises when absent, like `os.remove`); `exists` is a non-raising
    presence check (the pending-op finalize guards on it). A Phase-5 `SqliteKvStore`
    conforms to the SAME trait over one `kv(k,v)` table, swapped in at `default_kv_store()`.
    """

    def get(self, key: String) raises -> String:
        ...

    def set(self, key: String, value: String) raises:
        ...

    def delete(self, key: String) raises:
        ...

    def exists(self, key: String) -> Bool:
        ...


@fieldwise_init
struct FileKvStore(Copyable, KvStore, Movable):
    """The file-backed KV store: each key is a bare dotfile under `dir`, read/written
    WHOLE — the existing `_write_small` / inline-`open` logic moved verbatim. Holds only
    the base `dir` (the data dir); `key → dir + "/" + key`.

    `get` opens the file and returns its raw contents, RAISING on a missing/unreadable
    file exactly like the inline `with open(path, "r")` it replaces — the caller keeps its
    `.strip()` + `try/except → default`. `set` truncates + writes the value (the
    `_write_small` body WITHOUT the swallow — the thin `_kv_set` server facade keeps the
    best-effort `try/except`). `delete` = `os.remove`; `exists` = `os.path.exists` — both
    back the atomic-rename pending-op finalize.
    """

    var dir: String

    def _path(self, key: String) -> String:
        return self.dir + "/" + key

    def get(self, key: String) raises -> String:
        var content: String
        with open(self._path(key), "r") as f:
            content = f.read()
        return content

    def set(self, key: String, value: String) raises:
        with open(self._path(key), "w") as f:
            f.write(value)

    def delete(self, key: String) raises:
        remove(self._path(key))

    def exists(self, key: String) -> Bool:
        return exists(self._path(key))


def default_kv_store() -> FileKvStore:
    """The KV store the marker facades use — the single Phase-5 swap point. Today a
    file-backed store over the data dir (`_storage_config_dir()`), matching every
    marker's `<data-dir>/.<name>` path byte-for-byte."""
    return FileKvStore(_storage_config_dir())
