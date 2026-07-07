# Storage seam — design + migration roadmap

Status: **in progress** (Phase 2 of the backend architecture cleanup). This document
describes the `Store` abstraction that the app server's on-disk state is migrating
behind, and the order the remaining categories move. Cross-reference
[`ORCHESTRATOR.md`](./ORCHESTRATOR.md) — the work queue whose store lands in this
first slice is the same queue the orchestrator loop (§2.2–2.3) drives.

## 1. Why

The backend keeps **~20 on-disk state files in three formats** (TSV, JSONL, JSON,
plus a few bare marker files) and there is **no storage abstraction**: persistence is
smeared across ~150 direct file-I/O sites in `server.mojo` (`open(...)`, `f.read()`,
`f.write()`, tmp-rename, `flock`). Consequences:

- The on-disk **format is not swappable** — moving any category to SQLite (for atomic
  multi-file updates, concurrent reads, and querying) means editing every call site.
- The **durability discipline is inconsistent** — some writes are atomic (tmp +
  `rename`, e.g. the work queue), some are plain appends, some are bare overwrites.
- The same **path/lock/escape logic is re-derived** per file.

The fix is a small set of **`Store` traits** (one per access *shape*) with a
`FileStore` implementation today and a `SqliteStore` implementation later behind the
**same** traits — a one-flag swap, no call-site churn. This mirrors what `flare`
already does for its response cache (`flare/http/cache/store.mojo`: a `CacheStore`
trait, an in-memory impl now, a filesystem impl next — the middleware never changes).

## 2. The four store shapes

The ~20 files cluster into **four access patterns**. Each becomes a trait; a file
maps to exactly one by how it's read/written, not by its extension.

| Shape | Contract | Semantics |
|-------|----------|-----------|
| **kv** | `get(key)→val?` · `set(key,val)` · `delete(key)` | small single-value markers; last-write-wins |
| **log** | `append(record)` · `read_all()→raw` · `rewrite(raw)` | append-only event streams; torn last line tolerated **(migrated ✓)** |
| **queue** | `enqueue/peek/take/done/fail/list/running/reset` over `WorkItem` | ordered work items + a monotonic id; load-modify-save under a lock **(migrated ✓)** |
| **doc** | `load()→blob` · `save(blob)` | one structured document rewritten whole (registry / config / manifest) |

### 2.1 Current file → shape mapping

Drawn from the ~20 files under `~/Library/Application Support/Millfolio/data`
(override `MILLFOLIO_DATA_DIR`) and the install dir. Paths are the on-disk basenames.

| Shape | Files (today) | Format today |
|-------|---------------|--------------|
| **kv** | `.index.state` `.index.pid` `.index.log` `.index.op` `.index.runtotal` `.index.manifest` · `.model_download.state` · `.demo.state` · `.gpu_util` · `.anthropic-key` / `.reveal-secret` · `.search_cap.txt` `.search_out.json` | bare text / tiny marker files |
| **log** | `operations.jsonl` · `asks.jsonl` · `stats.jsonl` **← migrated (slice 2)** | append-only JSONL, newest-first read, cap on read |
| **queue** | `work_queue.jsonl` **← migrated (slice 1)** | TSV (one `WorkItem` per line) + `#nextid` header |
| **doc** | `categories.txt` · `indexed-paths.json` · `manifest.tsv` · `config.json` | whole-file rewrite (rules / tracked paths / index manifest / config) |

Note `work_queue.jsonl` keeps its historical `.jsonl` name for compatibility even
though its on-disk format is **TSV**, not JSON — the name predates the format choice
and the store preserves it byte-for-byte.

## 3. `FileStore` today, `SqliteStore` tomorrow — one trait, two backends

Each shape is a trait. `FileStore*` implements it with today's file logic moved
verbatim behind the interface; `SqliteStore*` (Phase 5) implements the **same** trait
over one `millfolio.db`:

```
        kv trait        log trait       queue trait      doc trait
           │               │               │               │
   ┌───────┴───────┬───────┴───────┬───────┴───────┬───────┴───────┐
FileKvStore    FileLogStore ✓ FileQueueStore ✓   FileDocStore     ← today (this cleanup)
SqliteKvStore  SqliteLogStore SqliteQueueStore   SqliteDocStore   ← Phase 5 (one table each)
```

- **kv** → a `kv(k TEXT PRIMARY KEY, v BLOB)` table.
- **log** → an `append`-only table with a rowid clock; `read` = `ORDER BY id DESC LIMIT cap`.
- **queue** → a `work_items` table + a `seq` counter; the load-modify-save becomes one
  transaction (no more whole-file rewrite, no `.lock`/`.tmp` siblings).
- **doc** → a single-row blob table (or normalized per-doc later).

**The swap is one line per store.** For the queue it's `default_queue_store()` in
`storage.mojo`; for a *runtime* config flag the delegator returns a
`Variant[FileQueueStore, SqliteQueueStore]` and dispatches once. No `wq_*` caller,
no `scheduler.mojo`, no `server.mojo` handler changes.

> **Phase 5 is out of scope here.** `SqliteStore` needs a Mojo `libsqlite3` FFI
> binding that does not exist yet (like flare's TLS/HTTP FFI shims, it would be a
> small `external_call` wrapper over the system `libsqlite3.dylib`). Building that
> binding — and the four `Sqlite*Store` impls — is Phase 5. This cleanup only lands
> the traits + the `File*Store` impls, so the seam is real and tested before the
> backend swap.

## 4. This slice — the queue seam (implemented)

The **work queue** is the cleanest category to prove the seam: it already had a clean
`wq_*` API over a single file with atomic writes.

- **`src/storage.mojo`** (new) — defines:
  - `trait QueueStore(Copyable, Movable)` — the queue contract:
    `enqueue / peek / take / done / fail / list / running / reset` over `WorkItem`.
  - `struct FileQueueStore(QueueStore, …)` — the **existing JSONL/TSV logic moved
    verbatim**: same file, same `flock(LOCK_EX)` on the `<path>.lock` sibling, same
    `<path>.tmp` + `rename()` atomic write, same `#nextid` id scheme, same
    torn-line-skip resilience, same `MILLFOLIO_WORKQ_PATH` override. The store holds
    only the state-file `path`; lock/tmp siblings are derived.
  - The `WorkItem` / `QueueState` records, the `PRIO_*` class defaults, and
    `work_queue_path()` — moved here so the store owns its record shape (keeps the
    module dependency **acyclic**: `work_queue → storage`, never back).
  - `default_queue_store()` — the single swap point (returns a `FileQueueStore` over
    `work_queue_path()` today).
- **`src/work_queue.mojo`** — now a **thin facade**. Re-exports `WorkItem` / `PRIO_*`
  / `work_queue_path` and reimplements each `wq_*` as a one-line delegator to
  `default_queue_store()`. So `scheduler.mojo`, `server.mojo`, and
  `test/work_queue_test.mojo` are **unchanged** and behavior is identical.

### Byte-identical guarantee

The persistence code was **moved, not rewritten** — same serialize/parse, same escape
rules, same header, same lock/rename calls. A store is constructed **fresh per `wq_*`
call** around `work_queue_path()`, so `MILLFOLIO_WORKQ_PATH` is re-read every
operation exactly as before (tests depend on this). `test/work_queue_test.mojo` passes
**unchanged** — priority/FIFO/dedup/lifecycle/persistence/corrupt-line invariants all
hold, which is the behavioral proof the on-disk format is untouched.

### Dispatch idiom chosen

A **trait + concrete-type** seam (the flare `CacheStore` pattern), with a
`default_queue_store()` factory as the swap point — **not** a runtime trait object.
Mojo's ergonomic path today is monomorphic: the `wq_*` delegators call methods on the
concrete `FileQueueStore` the factory returns, so there's zero dynamic-dispatch cost
and the code stays simple. When a second impl lands, the swap is either:

1. **compile-time** — change the factory's return type + delegators to a generic bound
   `def wq_enqueue[S: QueueStore](…)`; or
2. **runtime flag** — the factory returns `Variant[FileQueueStore, SqliteQueueStore]`
   and each delegator does a one-time `if store.isa[…]` dispatch.

Either way the `QueueStore` trait is the contract both impls satisfy; nothing above
the facade changes.

### Module home

`storage.mojo` lives in **`app/server/src`** for now, because the queue it backs lives
there. Once the vault-side stores are folded in (`vault/core`'s `derive/store`,
`derive/ledger` — the categorization registry + the ML-materialization ledger, which
are the *same* kv/doc shapes shared by the `mill` CLI and the app server in-process),
the shape traits should move to **`vault/core`** so both sides share one `Store`
definition and one `SqliteStore` backend. That is a later slice; keeping it in
`app/server` now avoids a premature cross-repo dependency while only the queue is
migrated.

## 4a. Slice 2 — the log seam (implemented)

The three **append-only JSONL logs** move behind one tiny trait, mirroring the queue:

- **`trait LogStore(Copyable, Movable)`** in `storage.mojo` — three methods:
  - `append(record: String)` — write one JSONL line (`record + "\n"`) then tighten the
    file to owner-only (`chmod 0600`). The record is the builder's output **without** a
    trailing newline (stats' line lost its old inline `"}\n"` → `"}"`, so all three
    logs now share one append path, byte-identical on disk).
  - `read_all() -> String` — the **raw** file contents, **raising on a missing file**
    exactly like the `with open(path, "r")` it replaces, so each caller keeps its own
    `try/except → empty`. It returns raw (not a pre-split/pre-skipped `List`) on
    purpose: the newest-first / cap / torn-line-skip logic stays in the **untouched**
    pure builders (`history_records_array`, `operations_records_array`, and stats'
    inline comma-join in `handle_stats`), so the HTTP output is provably byte-identical.
  - `rewrite(content: String)` — whole-file overwrite (no chmod; `"w"` preserves the
    existing owner-only mode) for the ask-history delete-record compaction
    (`POST /api/history/delete` → `delete_ask_records` → `rewrite`).
- **`struct FileLogStore(LogStore, …)`** — the existing `open`/`f.write`/`_chmod` logic
  moved verbatim; holds only the log's `path`.
- **Three factories** — `default_operations_store()` / `default_stats_store()` /
  `default_asks_store()` over `operations_log_path()` / `stats_log_path()` /
  `asks_log_path()` (honoring `MILLFOLIO_OPS_FILE` / `MILLFOLIO_STATS_FILE` /
  `MILLFOLIO_ASKS_FILE`). These are the Phase-5 swap points.
- **`server.mojo` is the thin facade**: `_append_operation` / `_append_stats` /
  `_append_ask` keep their best-effort `try/except → log("[…] append failed")`, now
  wrapping `store.append(...)`; the read handlers call `store.read_all()`; the delete
  handler calls `store.rewrite()`. `_operations_path` / `_stats_path` / `_asks_path`
  delegate to the storage path helpers (the System page still reads them). Behavior is
  unchanged. Unit-tested by `test/log_store_test.mojo` (`pixi run test-logstore`).

> **Out of scope (kv slice):** `operations.jsonl` pairs with the lazy-finalize **KV
> markers** `.index.op` / `.demo.op` (`_pending_op_path`, `_write_pending_op`) — those
> are a `kv`-shape file, migrated in slice 3, **not** here. Only the `.jsonl` append +
> read moved.

## 5. Migration order (remaining categories)

Smallest-surface / lowest-risk first, each shippable on its own:

1. **queue ✓** — slice 1 (one file, already had a clean API + atomic writes).
2. **logs ✓** — slice 2: `operations.jsonl` · `asks.jsonl` · `stats.jsonl`. Append +
   raw read behind `LogStore`; the builders stay in `store.mojo` (`ask_record_line`,
   `operation_record_line`, `*_records_array`), so the store is a thin bytes-mover over
   the file append/read. Uniform, well-bounded. See §4a.
3. **kv** — the `.index.*` / `.*.state` / `.gpu_util` / secret markers (plus the
   `.index.op` / `.demo.op` pending-op markers the log slice deliberately left). Many tiny
   sites; the win is consolidating scattered bare-file reads/writes behind
   `get/set/delete` (and later one `kv` table instead of a dozen dotfiles).
4. **docs** — `categories.txt` · `indexed-paths.json` · `manifest.tsv` · `config.json`.
   Whole-document rewrite; some are shared with `vault/core`, so this is the slice
   that motivates moving the traits down to `vault/core` (§4, module home).

Do **kv** next: the `.index.*` / `.*.state` / `.gpu_util` / secret + pending-op
markers — many tiny scattered bare-file reads/writes to consolidate behind
`get`/`set`/`delete`.
