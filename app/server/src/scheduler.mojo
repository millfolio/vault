"""Pure scheduling helpers for the work orchestrator (see `ORCHESTRATOR.md` §2.3–2.5).

The orchestrator loop in `server.mojo` owns the I/O (subprocess dispatch, engine
calls, the queue file); this module holds the **pure decision logic** at its seams so
each can be unit-tested hermetically (`test/scheduler_test.mojo`):

  - `index_run_plan` — the index generator's enqueue plan (prepare → per-file → finalize)
  - `split_payload` — decode a work item's tab-joined payload back to its fields
  - `index_active` / `index_pending_files` / `index_current` — `/api/index/status`
    derived from the queue contents (a running index run + how many files remain)
  - `query_active` — is an interactive chat/ask holding the engine (runqueue head≠tail)
  - `should_reconcile` — is a running item orphaned (its worker pid provably dead)
  - `parse_pending_total` — the backfill readiness signal (`pendingTotal` from status)

None of these touch disk or the network — the caller feeds them the queue snapshot,
the runqueue head/tail, a pid-liveness verdict, etc. — so they're deterministic.
"""
from work_queue import WorkItem, PRIO_INDEX, PRIO_FINALIZE, PRIO_BACKFILL


# ── work-item kinds ────────────────────────────────────────────────────────────
# An index RUN is driven as three item kinds enqueued together (all prio 10, ordered
# by id so they run prepare → files → finalize):
#   index-prepare  — run-level fresh/incremental setup (in-process, no engine)
#   index          — embed ONE file (detached `millfolio index-file <base> <path>`)
#   finalize       — settle the manifest (detached `millfolio index-finalize …`)
comptime KIND_PREPARE = "index-prepare"
comptime KIND_INDEX = "index"
comptime KIND_FINALIZE = "finalize"
comptime KIND_BACKFILL = "backfill"
# The first-run sample-data import: ONE item that downloads + unpacks the demo vault
# (via flare's HttpClient, off-reactor in the orchestrator loop), then enqueues a
# normal index run over it. Not an index kind (no engine); runs at index priority so
# it's picked ahead of backfill. See server.mojo `_run_demo_download_item`.
comptime KIND_DEMO = "demo-download"

# The single payload separator. `work_queue` escapes tabs on serialize, so an embedded
# `\t` round-trips through the queue file intact and can safely delimit sub-fields.
comptime PAYLOAD_SEP = "\t"


def is_index_kind(kind: String) -> Bool:
    """True for the three kinds that together mean 'an index run is in flight'.
    """
    return kind == KIND_PREPARE or kind == KIND_INDEX or kind == KIND_FINALIZE


# ── the index generator's enqueue plan ─────────────────────────────────────────


@fieldwise_init
struct EnqSpec(Copyable, Movable):
    """One (kind, payload, prio) the generator will `wq_enqueue` (enq_at supplied by
    the caller). Pure data so the plan can be asserted without touching the queue.
    """

    var kind: String
    var payload: String
    var prio: Int


def index_run_plan(base: String, files: List[String]) -> List[EnqSpec]:
    """The ordered enqueue plan for one index run over `files` (all named relative to
    `base`): a single prepare, one index item per file, then a finalize carrying the
    whole tracked set. Payloads are tab-joined: prepare=`base`, index=`base\\tpath`,
    finalize=`base\\tpath1\\tpath2…`. All prio 10 (finalize enqueued LAST → highest id
    → runs last); dedup on (kind,payload) coalesces a repeated per-file item."""
    var out = List[EnqSpec]()
    out.append(EnqSpec(String(KIND_PREPARE), base, PRIO_INDEX))
    for i in range(len(files)):
        out.append(
            EnqSpec(
                String(KIND_INDEX), base + PAYLOAD_SEP + files[i], PRIO_INDEX
            )
        )
    var fin = base
    for i in range(len(files)):
        fin += PAYLOAD_SEP + files[i]
    out.append(EnqSpec(String(KIND_FINALIZE), fin^, PRIO_FINALIZE))
    return out^


def split_payload(payload: String) raises -> List[String]:
    """Decode a tab-joined payload into its fields (`base`, then any file paths).
    """
    var out = List[String]()
    for part in payload.split(PAYLOAD_SEP):
        out.append(String(part))
    return out^


def basename(p: String) -> String:
    """The last path component of `p` (after the final '/'); `p` itself if it has no
    slash. Trailing-slash paths yield '' — acceptable for a display label."""
    var parts = p.split("/")
    if len(parts) == 0:
        return p
    return String(parts[len(parts) - 1])


def short_payload(kind: String, payload: String) raises -> String:
    """A compact, path-free rendering of a work item's payload for the UI queue view:
    an `index` item → the file's basename; `finalize` → 'N files'; `index-prepare` →
    the base folder's basename; `backfill`/other → the payload unchanged (already a
    short scope). Keeps absolute on-device paths out of the queue endpoint."""
    var parts = split_payload(payload)
    if kind == KIND_FINALIZE:
        var n = len(parts) - 1
        if n < 0:
            n = 0
        return String(n) + (" file" if n == 1 else " files")
    if kind == KIND_INDEX:
        if len(parts) >= 2:
            return basename(String(parts[len(parts) - 1]))
        return basename(payload)
    if kind == KIND_PREPARE:
        if len(parts) >= 1:
            return basename(String(parts[0]))
        return payload
    if kind == KIND_DEMO:
        return String("sample data")
    return payload


# ── /api/index/status derived from the queue ───────────────────────────────────


def index_active(items: List[WorkItem]) -> Bool:
    """True if any index-family item (prepare/index/finalize) is queued or running —
    the queue-derived replacement for the old `.index.state == indexing` flag.
    """
    for i in range(len(items)):
        if is_index_kind(items[i].kind):
            return True
    return False


def index_pending_files(items: List[WorkItem]) -> Int:
    """How many per-file `index` items are still PENDING (not yet started)."""
    var n = 0
    for i in range(len(items)):
        if items[i].kind == KIND_INDEX and items[i].state == "pending":
            n += 1
    return n


def index_current(total: Int, items: List[WorkItem]) -> Int:
    """The 'n of M files' current count for the progress bar: files already started
    or done = `total − pending`, clamped to [0, total]."""
    var cur = total - index_pending_files(items)
    if cur < 0:
        return 0
    if cur > total:
        return total
    return cur


# ── loop gating predicates ─────────────────────────────────────────────────────


def query_active(head: Int, tail: Int) -> Bool:
    """An interactive chat/ask holds (or is waiting for) the engine when the runqueue
    has an outstanding ticket — `tail > head`. Background work yields to it."""
    return tail > head


def should_reconcile(state: String, alive: Bool) -> Bool:
    """A running item is orphaned (its run crashed / the owning process is gone) when
    it's marked running but its recorded worker pid is provably dead. `alive` is the
    caller's `kill(pid,0)` verdict; only a provably-dead pid reconciles."""
    return state == "running" and not alive


# ── backfill readiness signal ──────────────────────────────────────────────────


def parse_pending_total(status_json: String) -> Int:
    """Read `"pendingTotal":<int>` out of `backfill_status_json()` — the count of ML
    generations still to classify. >0 means the backfill generator should enqueue a
    slice; 0 means idle (enqueue nothing). Tolerant scan (0 if absent/malformed).
    """
    var key = String('"pendingTotal":')
    var at = status_json.find(key)
    if at < 0:
        return 0
    var i = at + key.byte_length()
    var b = status_json.as_bytes()
    var neg = i < len(b) and Int(b[i]) == 45  # '-'
    if neg:
        i += 1
    var v = 0
    var any = False
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        v = v * 10 + (Int(b[i]) - 48)
        any = True
        i += 1
    if not any:
        return 0
    return -v if neg else v
