# Work Harness — design

Status: **implemented** (Phases 0–4 landed; Phase 5 optional). This document describes
where the app server's background work — **indexing** and **AI-tag backfill** — lands,
and how we got there incrementally from the old point-fixes. It is the plan behind
unifying the System/Backfill UI under **Operations** and making **pause + priority
global**.

### Code layout (where the pieces live)

The orchestrator is split across small modules over `vault.storage`, all imported
by `server.mojo` (which keeps only the HTTP surface). The dependency graph is
acyclic — none of these import `server.mojo`:

| Module | Owns |
|--------|------|
| `work_queue.mojo` | the disk-backed `WorkItem` queue facade (`wq_*`) over `vault.storage` |
| `scheduler.mojo` | the PURE scheduling seams (enqueue plan, queue-derived status, pause/query gating, reconcile predicate, backfill readiness) — unit-tested, no I/O |
| `runqueue.mojo` | the interactive chat/ask FIFO ticket (the "a query is running" signal) |
| **`work_orchestrator.mojo`** | **the orchestrator RUNTIME: the `_orchestrator_worker` pthread loop (§2.3) + its job runners (`_run_index_item`/`_run_index_child`/`_run_demo_download_item`/`_demo_fetch_and_unpack`), the boot/loop `_reconcile_stale` (§2.5), the `_start_index_run` generator (§2.1), and the index/demo run STATE + OPERATIONS-recording helpers those read/write (markers, `operations.jsonl` append, `_finalize_index_op`).** |

`server.mojo` still **spawns** the loop
(`ThreadHandle.spawn[_orchestrator_worker]`) at startup and runs the boot
`_reconcile_stale()`. The **HTTP handlers** (`/api/orchestrator/*`,
`/api/index|reindex`, `/api/demo/download`) + the **status-JSON builders**
(`_index_status_json`, `_demo_status_json`, `_orchestrator_queue_json`, …) live in
`handlers_operations.mojo` / `handlers_demo.mojo` (the Phase-1B per-domain carve-up;
`server.mojo` is only the route dispatcher + `main()`) — those
call into `work_orchestrator`'s enqueue/run/state helpers. Global **pause + priority**
+ the readiness/backfill drain live in `vault.derive.store`
(`is_paused`/`get_priority`/`nap_ms_for_priority`/`ml_backfill_slice`).

## 1. Why

The app server drives an on-device engine that serves *both* embeddings (indexing)
and classification (AI-tag backfill), plus interactive chat/ask. Today these run
through **three unrelated mechanisms** with no shared scheduler:

| Work | How it runs today | Coordinated? |
|------|-------------------|--------------|
| Interactive chat/ask | `runqueue.mojo` — a disk-backed **FIFO ticket** queue (`runq_take`/`runq_done`), one run at a time per port | ✅ but only among queries |
| Re-index | `_start_index_detached` — a **detached shell process** (`MILLFOLIO_RUN_SCRIPT`), state in `.index.state` + `.index.pid` | ❌ independent |
| AI-tag backfill | `_backfill_worker` — a **polling thread** calling `ml_backfill_slice` every ~3s | ❌ independent |

Because index and backfill are independent and both hammer the one engine, they
**contend**: a live repro had the backfill worker starving a `procversion→4`
re-index so it never finished writing `manifest.tsv`, wedging the vault. We've since
added two point-fixes — *backfill yields while `_index_running()`* and a
*PID-liveness guard + boot reconciliation* for stale `indexing` state — but those are
patches over a missing abstraction. The user-facing controls are also fragmented:
**pause** and **priority** live only under Backfill, even though they should govern
*all* background engine work; and the state is split across the **System**,
**Backfill**, and **Operations** panels.

The fix is a single **orchestrator**: work generators enqueue **work items**; one
scheduler decides what runs next based on the queue + global config; exactly one
background job touches the engine at a time; interactive queries take precedence.

## 2. Target architecture

```
  ┌──────────────────┐        ┌──────────────────┐
  │ Index generator  │        │ Backfill         │
  │ (re-index req →  │        │ generator        │
  │  one item / file)│        │ (pending ML gens │
  └────────┬─────────┘        │  → backfill items)│
           │                  └────────┬─────────┘
           │  enqueue                  │  enqueue
           ▼                           ▼
        ┌──────────────────────────────────────┐
        │        Work queue (disk-backed)       │   ← survives restart;
        │  items: {id,kind,payload,enq_at,prio} │     extends runqueue.mojo
        └───────────────────┬──────────────────┘
                            │  peek / take
                            ▼
        ┌──────────────────────────────────────┐
        │            Harness loop          │
        │  reads queue + global config (pause,  │
        │  priority) → pick next / wait; ONE     │
        │  background job on the engine at a time│
        │  interactive query → yields/preempts   │
        └───────────────────┬──────────────────┘
                            │  run
                            ▼
        ┌──────────────────────────────────────┐
        │  Running marker: {item_id, pid, ts}   │  → stale/crash detection
        │  on start; cleared on done/fail       │     (kill(pid,0) + ts age)
        └──────────────────────────────────────┘
                            │
                            ▼   completion / failure
              Operations log (operations.jsonl)  → Operations UI
```

### 2.1 Work items

A work item is a small, serializable record. Both generators produce the same shape
so the orchestrator treats them uniformly.

```
WorkItem {
  id:       string        # monotonic, stable across restart
  kind:     "index" | "backfill"
  payload:  string        # index: ONE file to embed (path/alias); a final
                          #   "finalize" item settles the manifest;
                          # backfill: the generation-group / rule scope to drain
  enq_at:   epoch_s       # for FIFO-within-priority + age
  prio:     int           # class priority (see §2.4); default by kind
}
```

- **Index generator** — the existing `POST /api/index` / `/api/reindex` handlers stop
  spawning directly; they **enumerate the files (the tracked-paths union) and enqueue
  one `index` item per file** (embed *this file* → its chunks + txn rows + manifest
  row), plus a final **finalize** item that settles the manifest once all file items
  complete. Per-file granularity is deliberate: the orchestrator re-checks
  pause/priority **at each file boundary** — exactly like backfill between
  generation-groups — so a re-index can be **paused, or yield to an interactive query,
  between files** instead of only after the whole run. Re-requests coalesce/dedup by
  file (never two items for the same file queued at once). The "an index job is already
  running" guard becomes "index items are queued or running."
- **Backfill generator** — instead of a free-running poll, the readiness signal
  (pending ML generations exist: `added_gen > done_gen` for some rule) **enqueues
  `backfill` items**, one per generation-group slice (mirrors today's
  `ml_backfill_slice` bound of one gen-group). When the drain reports "nothing
  pending," it stops enqueuing. This keeps the existing incremental, resumable
  ledger semantics — the queue just decides *when* a slice runs.

### 2.2 The queue (disk-backed, extends `runqueue.mojo`)

We already have a **disk-backed FIFO** in `runqueue.mojo` — a per-port ticket
counter that serializes chat/ask runs and survives process death (state in a file,
`MILLFOLIO_RUNQ_PATH`). The orchestrator's work queue is the same idea, **generalized
from an integer ticket to a small list of `WorkItem` records**:

- Persisted next to the other index state under `_config_dir()` (e.g.
  `work_queue.jsonl`), so a restart resumes exactly where it left off — no lost or
  duplicated jobs.
- API (extends the `runq_*` family): `wq_enqueue(item)`, `wq_peek() -> item?`,
  `wq_take(id)`, `wq_done(id)`, `wq_fail(id, reason)`. Same lock discipline as
  `runqueue.mojo` (a torn write is recoverable; unit-tested like
  `test/runqueue_test.mojo`).
- Interactive chat/ask keeps its **own** fast ticket queue (latency-sensitive, no
  disk round-trip per token). The orchestrator simply treats "a query is running" as
  a top-priority signal to pause background work (see §2.4). We do **not** funnel
  every chat token through the work queue.

### 2.3 The orchestrator loop

A single loop (replacing the independent `_backfill_worker` poll) owns all background
engine work:

```
loop:
  reconcile_stale()                     # crash recovery — see §2.5
  if paused_until > now:                # global pause (§2.4)
      sleep(min(remaining_pause, tick)); continue
  if interactive_query_running():       # a chat/ask holds the engine
      sleep(short); continue            # background work yields to queries
  item = wq_peek_highest_priority()     # index > backfill; FIFO within a class
  if item is None:
      sleep(idle_tick_for(priority));   # nothing to do — nap per priority
      maybe_enqueue_backfill_if_pending()
      continue
  run(item)                             # ONE job; blocks the loop until done/fail
```

- **One background job at a time** — the loop is serial, so index and backfill can
  never contend for the engine again. The §1 stall becomes structurally impossible.
- `run(item)` writes the **running marker** (§2.5), executes (detached index process
  *or* an in-process backfill slice), then `wq_done`/`wq_fail` and appends to the
  operations log.

### 2.4 Global config — pause + priority (moved out of Backfill)

Today `set_pause`/`get_priority` gate only the backfill thread
(`/api/backfill/pause`, `/api/backfill/priority`). They become **orchestrator-global**:

- **Pause** — `paused_until` halts *all* background work (index *and* backfill). The
  "Pause for 1 hr" control sets `paused_until = now + 1h`. A queued index item simply
  waits; interactive chat/ask is **never** paused (queries always run).
- **Priority** — a single global setting (`low`/`normal`/`high`) governs how
  aggressively the orchestrator runs background work: the idle/inter-slice nap
  (`nap_ms_for_priority`) and whether it leaves GPU-idle gaps (laptop stays usable on
  `low`) or runs near back-to-back (`high`). **Class priority** (interactive > index
  > backfill) is fixed and separate from this user knob.
- Endpoints migrate: `/api/backfill/pause` + `/api/backfill/priority` →
  `/api/orchestrator/pause` + `/api/orchestrator/priority` (keep the old routes as
  thin aliases for one release).

### 2.5 Running marker + staleness detection

When a job starts, persist a **running marker** — `{item_id, pid, started_ts}`:

- **PID** — for an index item, the detached worker PID (already captured in
  `.index.pid`); for a backfill slice, the server's own PID (in-process). Liveness via
  `kill(pid, 0)` (== 0 → alive; `ESRCH` → dead). This generalizes the point-fix now
  in `_index_read_state()`.
- **Timestamp** — `started_ts` (and optionally a `last_progress_ts` heartbeat) bounds
  a job that's alive-but-wedged: a run older than a generous ceiling with no progress
  is treated as stale.
- `reconcile_stale()` (loop head **and** on boot): a marker whose **PID is provably
  dead** (or whose heartbeat is provably stale) → the job **failed**; clear the marker
  + requeue-or-drop per kind, and record a `failed` op. This is what makes a crashed
  run stop wedging the queue and survive `stop`/`start` cleanly — the generalization
  of `_reconcile_index_state_on_boot()`.

### 2.6 Failure surfacing → Operations

A failed job (dead PID / stale heartbeat / non-zero exit) is written to the
operations log as `status:"error"` with the captured `pid`, `started_ts`, and reason,
so **Operations** shows it plainly:

> **Index** ✗ failed · worker pid 41821 exited (no manifest) · Jul 5 3:12 PM

The live "running" row is driven by the running marker (not a bare state flag), so a
dead PID clears it immediately instead of hanging as "running" forever.

## 3. UI — fold System + Backfill into Operations

Today: **System** (GPU/mem/disk + model info), **Backfill** (pause/priority + per-tag
progress), **Operations** (index/backfill/reindex history + the live row). Target: a
single **Operations** tab that is the one place for "what is the machine doing":

- **Now** — the running job (kind, progress, pid, elapsed) + what's queued behind it.
- **Controls** — global **Pause for 1 hr** + **Priority** (low/normal/high), governing
  index *and* backfill (moved out of the Backfill panel).
- **History** — the operations log, newest first, with **failed jobs surfaced** (pid +
  reason), durations guarded (the `fmtDur` sanity clamp already in place).
- **System** — GPU/mem/disk + model info folded in as a sub-section (from
  `SystemPanel.svelte`), since it's the same "system status" story.
- `BackfillPanel.svelte` + `SystemPanel.svelte` are absorbed into
  `OperationsPanel.svelte`; per-tag backfill progress becomes a detail of the running
  backfill job. Tag *definitions/editing* stay in the Tags tab — Operations is about
  *execution*, not configuration.

## 4. Build plan (incremental — nothing big-bang)

Each step is shippable on its own; we already did Phase 0.

- **Phase 0 (done)** — point-fixes: backfill yields to `_index_running()`; PID-liveness
  guard + boot reconciliation; `fmtDur` clamp; tag names in backfill ops.
- **Phase 1 — global pause/priority.** Rename backfill pause/priority to
  orchestrator-global; make the index path also respect `paused_until`. Move the
  controls into Operations. (Small; no queue yet.)
- **Phase 2 — the work queue.** Generalize `runqueue.mojo` into `work_queue`
  (`WorkItem` list, `wq_*` API, unit tests). Index + backfill generators enqueue
  instead of running directly.
- **Phase 3 — the orchestrator loop.** Replace `_backfill_worker`'s free poll with the
  single loop (§2.3); one background job at a time; running marker generalized from
  `.index.pid`. **(Later isolated into `work_orchestrator.mojo` — see "Code layout"
  above — lifting the loop + job runners + run-state/operations helpers out of the
  `server.mojo` god-file with zero behaviour change; `server.mojo` imports them back.)**
- **Phase 4 — UI unification.** Absorb System + Backfill into Operations; surface
  failed pids; show the queue.
- **Phase 5 — (optional) interactive preemption.** Let a chat/ask *preempt* a
  low-priority backfill slice (checkpoint at a gen-group boundary) rather than just
  waiting for the current slice — only if query latency during backfill proves to be a
  problem.

## 5. Open questions

- **Preemption granularity** — both generators are now sliced: backfill per
  generation-group, **index per file**, so the orchestrator can pause or yield to a
  query at each file boundary. The remaining edge is a **single very large file** (e.g.
  the 554-chunk `Jan 01 2025 – Jul 01 2026.csv`): one file is still one indivisible
  unit, so a pause can wait up to one big-file embed. If that proves too coarse, slice
  within a file (per-chunk-batch); file granularity is the pragmatic default.
- **Multi-host** — the demo runs a separate engine/host; the queue is per-install, so
  no change there, but worth confirming the marker's PID semantics on the demo's
  worker model.
- **Fairness** — with only two background kinds and index > backfill, starvation isn't
  a real risk (index is finite and rare). If more kinds appear (re-embed on model
  change, dedup passes), revisit whether strict class priority needs aging.
