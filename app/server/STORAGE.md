# Storage seam — design + migration roadmap

Status: **Phase 2 COMPLETE** (of the backend architecture cleanup). All four store
shapes — **queue / log / kv / doc** — now live behind `vault.storage` traits with
`File*` implementations; a Phase-5 `SqliteStore` implements the same four traits for a
one-flag swap. This document
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
| **kv** | `get(key)→val` · `set(key,val)` · `delete(key)` · `exists(key)` | small single-value markers; last-write-wins **(migrated ✓)** |
| **log** | `append(record)` · `read_all()→raw` · `rewrite(raw)` | append-only event streams; torn last line tolerated **(migrated ✓)** |
| **queue** | `enqueue/peek/take/done/fail/list/running/reset` over `WorkItem` | ordered work items + a monotonic id; load-modify-save under a lock **(migrated ✓)** |
| **doc** | `load(key)→blob` · `save(key,blob)` | one structured document rewritten whole (registry / config / manifest) **(migrated ✓)** |

### 2.1 Current file → shape mapping

Drawn from the ~20 files under `~/Library/Application Support/Millfolio/data`
(override `MILLFOLIO_DATA_DIR`) and the install dir. Paths are the on-disk basenames.

| Shape | Files (today) | Format today |
|-------|---------------|--------------|
| **kv** | `.index.state` `.index.pid` `.index.op` `.index.runtotal` · `.model_download.state` `.model_download.model` · `.demo.state` `.demo.op` **← migrated (slice 3)** · _(left in place:_ `.anthropic-key` / `.reveal-secret` _— auth 0600;_ `.gpu_util` `.mem_bytes` `.mem_used` `.disk_used` `.dl_du` _— sysmetrics shell-redirect caches;_ `.index.log` `.demo.log` `.model_download.log` _— logs)_ | bare text / tiny marker files |
| **log** | `operations.jsonl` · `asks.jsonl` · `stats.jsonl` **← migrated (slice 2)** | append-only JSONL, newest-first read, cap on read |
| **queue** | `work_queue.jsonl` **← migrated (slice 1)** | TSV (one `WorkItem` per line) + `#nextid` header |
| **doc** | `categories.txt` · `indexed-paths.json` · `manifest.tsv` **← migrated (slice B2)** · _(left: `config.json` — not yet a live doc)_ | whole-file rewrite (rules / tracked paths / index manifest) |

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
FileKvStore ✓  FileLogStore ✓ FileQueueStore ✓   FileDocStore ✓   ← today (this cleanup)
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

### Module home — **now `vault/core` (`vault.storage`)** (Phase 2 slice B1, done)

The storage layer was **promoted out of `app/server/src/storage.mojo` into
`vault/core/src/vault/storage/`** — the `vault.storage` sub-package (import
`from vault.storage import …`; sibling to `vault.derive` / `vault.index` /
`vault.extract`). Both sides now share one `Store` definition + one future
`SqliteStore` backend: the app server AND the vault-side registries (`derive/store`,
`derive/ledger` — the categorization registry + ML-materialization ledger, the *same*
kv/doc shapes the `mill` CLI and the server use in-process).

- **Not on the `from vault import *` tool surface.** `vault.storage` is internal
  infra, deliberately left OUT of `vault/core/src/vault/__init__.mojo`'s wildcard — a
  privacy_box-generated program can't reach it; it's importable only by name.
- **Acyclic.** `vault.storage` depends on nothing but stdlib + the `flare` sibling lib
  (for `MutUntrackedOrigin`) — it imports NOTHING from `app/server`. The two helpers it
  used to borrow from the server (`osutil._config_dir` for the data dir, `osutil._chmod`
  for the owner-only log mode) are **inlined** as `_storage_config_dir()` +
  `_chmod()` (option (b): a minimal self-contained resolver, chosen over parameterizing
  every factory — the resolver is one env read + a libc `chmod`, and inlining reproduces
  the exact on-disk paths + 0600 modes byte-for-byte with zero cross-repo coupling). The
  `WorkItem`/`QueueState`/`PRIO_*` records move with it — plain records, no app-server
  dependency.
- **Re-wire.** `app/server`'s facades now `from vault.storage import …`: `work_queue.mojo`
  (the `wq_*` delegators), `server.mojo` (the log/kv facades), the test tasks. app/server
  already built with `-I ../../vault/core/src` (for `vault.derive.*`), so the server build
  needed no new include; the `test-workqueue` / `test-logstore` / `test-kvstore` /
  `test-scheduler` pixi tasks each gained `-I ../../vault/core/src`.
- **Precompile/bundle.** `precompile_pkgs.sh` runs `mojo precompile core/src/vault`, which
  compiles EVERY file in the package — so the new `vault/storage/` sub-package is folded
  into `vault.mojoc` automatically (no script change), and the app-server resolves
  `vault.storage` from the compiled package exactly as it resolves `vault.derive`.

This slice is a **pure move + re-wire** — behaviour and on-disk formats are byte-identical.
The next slice (**B2 — docs**: `categories.txt` / `indexed-paths.json` / `manifest.tsv` /
`config.json`, the shapes actually shared with `vault/core`) is what this relocation
unblocks; it lands the `DocStore` and migrates those registries.

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

## 4b. Slice 3 — the KV / small-marker seam (implemented)

The tiny **single-value marker dotfiles** move behind one `KvStore` trait, mirroring the
queue + log slices:

- **`trait KvStore(Copyable, Movable)`** in `storage.mojo` — four methods:
  - `get(key) -> String` — the WHOLE stored value, **raising on a missing key** exactly
    like the inline `with open(path, "r")` each marker read replaces, so every caller
    keeps its own `try/except → default` + `.strip()`.
  - `set(key, value)` — write the value WHOLE (last-write-wins; the `_write_small` body
    minus its swallow — the thin `_kv_set` server facade keeps the best-effort
    `try/except`).
  - `delete(key)` — remove it (raises when absent, like `os.remove`).
  - `exists(key) -> Bool` — non-raising presence check (the lazy-finalize pending-op
    guards on it).
- **`struct FileKvStore(KvStore, …)`** — the existing `_write_small` / inline-`open` logic
  moved verbatim; holds only the base `dir` and maps a **logical key** (the marker's
  basename, e.g. `.index.state`) to `dir + "/" + key`. Keys are logical names, NOT
  filesystem paths, so a Phase-5 `SqliteKvStore` reuses the SAME keys as the primary key
  of one `kv(k,v)` table.
- **`default_kv_store()`** over `_config_dir()` — the Phase-5 swap point; reproduces every
  marker's old `_config_dir() + "/.<name>"` path byte-for-byte.
- **`server.mojo` is the thin facade**: the marker path helpers (`_index_state_path`,
  `_dl_state_path`, `_demo_state_path`, `_pending_op_path`, …) now derive from the key
  constants; writes go through `_kv_set(KEY, …)`, reads through `default_kv_store().get(KEY)`
  (inside their existing `try/except → default`), and the pending-op finalizers' presence
  check through `.exists(KEY)`. Behavior is unchanged. Unit-tested by
  `test/kv_store_test.mojo` (`pixi run test-kvstore`, hermetic over a temp `MILLFOLIO_DATA_DIR`).

**Eight migrated markers** (logical keys, all written/read WHOLE in-process):
`.index.state` · `.index.pid` · `.index.op` · `.index.runtotal` · `.demo.state` ·
`.demo.op` · `.model_download.state` · `.model_download.model`. This picks up the
**pending-op markers `.index.op` / `.demo.op`** the log slice explicitly deferred (their
WRITE + the finalizer's `exists()` guard now route through the store; the finalizer's
atomic-rename *claim* to a `.claiming` sibling stays as bespoke orchestration — it isn't a
get/set/delete/exists primitive, and `.claiming` isn't a marker).

> **Deliberately NOT migrated:**
> - **Auth 0600 secrets** `.anthropic-key` / `.reveal-secret` — they live in `auth.mojo`
>   with `chmod 0600` semantics + their own tests. A plain `KvStore.set` opens `"w"` and
>   would NOT re-tighten the mode, so forcing them through the store would weaken the file
>   mode. Left in `auth.mojo`; `auth_test` stays green.
> - **Scratch metric caches** `.gpu_util` / `.mem_bytes` / `.mem_used` / `.disk_used` (in
>   `sysmetrics.mojo`) and `.dl_du` (in `_du_bytes`) — these are WRITTEN BY A SHELL REDIRECT
>   (`… > '<path>'`) inside a `system()` subprocess; only their READ is Mojo. The write
>   can't route through a Mojo `set` (and a subprocess can't write to a future SQLite
>   backend), so they're not "clean" KV — they're throwaway subprocess-to-temp-file IPC.
>   Left in place.
> - **Logs** `.index.log` / `.demo.log` / `.model_download.log` — append + last-line-read
>   captured-output streams, not single-value markers. (`.model_download.state`'s
>   *completion* flip in the detached-download path is also a shell `printf … > state`
>   redirect — but its other writes/reads are genuine in-process KV, so it's migrated; a
>   Phase-5 SQLite swap would additionally need to reroute that one shell step.)

## 4c. Slice B2 — the doc seam (implemented) — Phase 2 FINAL slice

The structured **whole-document rewrites** move behind one `DocStore` trait, completing
Phase 2. Because two of the three docs are owned by `vault/core` (the tag registry + the
index manifest), the trait lands in `vault.storage` (where slice B1 had already promoted
the layer) so both the app server AND the vault-side owners share it in-process:

- **`trait DocStore(Copyable, Movable)`** in `storage.mojo` — two methods:
  - `load(key) -> String` — the WHOLE document, **raising on a missing doc** exactly
    like the inline `with open(path, "r")` each owner replaces, so every owner keeps its
    own `exists()`-guard / `try/except`.
  - `save(key, content)` — write the document WHOLE with a plain `"w"` open (truncate +
    replace; the same **default-umask mode** the originals used — docs are NOT tightened
    to 0600 like the log/kv-secret files, they hold no raw amounts).
- **`struct FileDocStore(DocStore, …)`** — the existing inline `open` logic moved verbatim;
  holds only the base `dir` and maps a **logical key** (the doc's basename, e.g.
  `categories.txt`) to `dir + "/" + key`, mirroring `FileKvStore`. Keys are logical names,
  NOT filesystem paths, so a Phase-5 `SqliteDocStore` reuses the SAME keys as the primary
  key of one `docs(k,v)` table.
- **Three factories** (the Phase-5 swap points) + key constants `DOC_CATEGORIES` /
  `DOC_MANIFEST` / `DOC_INDEXED_PATHS`:
  - `default_categories_store()` over the data dir — `categories_path()` byte-for-byte.
  - `default_manifest_store(dir)` — **parameterized by dir** because the manifest is read
    from more than one location (the index owner + the app server use the data dir).
  - `default_indexed_paths_store()` over the data dir — `_tracked_paths_path()` byte-for-byte.
- **The owners are thin facades — all document STRUCTURE stays put, the store only moves
  bytes:**
  - **`categories.txt`** (`vault.derive.tags`): `write_categories` + the two reads
    (`load_registry` / `read_categories`) route through the store, but **the registry's
    refresh-if-untouched decision, the `# managed-checksum:` logic, rule parsing, and the
    tag-name rules are UNCHANGED**. The store performs only the I/O the registry used to do
    inline; the registry still decides WHEN to read/refresh/write. `write_categories`
    keeps its best-effort `try/except` swallow + `ensure_data_dir()`. Proven byte-identical
    by `test-store` / `test-persist` / **`test-missing-defaults`** (the categories-refresh
    test), all still green unchanged.
  - **`manifest.tsv`** (`vault.index`): `_load_manifest` read + `_write_manifest` write route
    through `default_manifest_store(config_dir())`; the `#meta` header + TSV serialize/parse
    are untouched. The app server's three manifest READERS (`handle_vault`, the alias→path
    resolve, `_indexed_file_count`) route through the store too. The `privacy-box` sandbox
    readers (a different, sandbox-granted dir) are left as-is. Proven byte-identical by
    **`test-golden`** / `test-index-steps` / `test-procversion`, all still green.
  - **`indexed-paths.json`** (app-side `server.mojo`): `_read_tracked` read + `_write_tracked`
    write route through `default_indexed_paths_store()`; the JSON build/parse is unchanged
    and the write keeps `_write_small`'s best-effort swallow.
- Unit-tested by `test/storage/doc_store_test.mojo` (`pixi run test-docstore` in `vault`,
  hermetic over a temp `MILLFOLIO_DATA_DIR`): load-missing-raises, save→load roundtrip,
  overwrite (last-write-wins), plain-umask mode, and the per-doc factories.

> **Out of scope:** `config.json` is listed as a doc-shape file but isn't a live read/write
> site yet, so it's left for whenever it lands. The `privacy-box` manifest readers stay
> inline (they read a sandbox-granted dir, not `vault.storage`, and `sandbox_test` builds
> without `-I core/src`).

**Phase 2 is done.** All four shapes (queue / log / kv / doc) sit behind `vault.storage`
traits with `File*` impls; the on-disk format is now swappable without call-site churn. A
Phase-5 `SqliteStore` implements the four traits (`SqliteQueueStore` / `SqliteLogStore` /
`SqliteKvStore` / `SqliteDocStore`) over one `millfolio.db` for a **one-flag swap** at the
`default_*_store()` factories — no facade, no owner, no handler changes. That (plus the
`libsqlite3` FFI binding it needs) is the only remaining storage work.

## 5. Migration order (remaining categories)

Smallest-surface / lowest-risk first, each shippable on its own:

1. **queue ✓** — slice 1 (one file, already had a clean API + atomic writes).
2. **logs ✓** — slice 2: `operations.jsonl` · `asks.jsonl` · `stats.jsonl`. Append +
   raw read behind `LogStore`; the builders stay in `store.mojo` (`ask_record_line`,
   `operation_record_line`, `*_records_array`), so the store is a thin bytes-mover over
   the file append/read. Uniform, well-bounded. See §4a.
3. **kv ✓** — slice 3: the `.index.*` / `.*.state` / `.*.op` / `.model_download.*` markers
   (incl. the `.index.op` / `.demo.op` pending-op markers the log slice deliberately left).
   Many tiny sites consolidated behind `get/set/delete/exists` (and later one `kv` table
   instead of a dozen dotfiles). Auth 0600 secrets + the sysmetrics shell-redirect scratch
   caches stay put (see §4b). See §4b.
4. **docs ✓** — slice B2: `categories.txt` · `indexed-paths.json` · `manifest.tsv` behind
   `DocStore`; all document STRUCTURE stays in the owners (`vault.derive.tags` /
   `vault.index` / `server.mojo`), the store only moves bytes. Some are shared with
   `vault/core`, which is why the shape traits were **already promoted** to `vault/core`
   (`vault.storage`, §4 module home) in slice B1 ahead of this — so the shared `DocStore`
   lands where both sides use it. See §4c.

**Slice B1 (done):** the whole storage layer moved from `app/server/src/storage.mojo` to
`vault/core`'s `vault.storage` sub-package (§4 module home) — a pure move + re-wire.
**Slice B2 (done):** landed `DocStore` in `vault.storage` and migrated `categories.txt` ·
`indexed-paths.json` · `manifest.tsv` behind it (§4c) — **Phase 2 COMPLETE**. The only
remaining storage work is Phase 5 (the `SqliteStore` backend + its `libsqlite3` FFI).
