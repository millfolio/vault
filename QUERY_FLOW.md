# Query flow — derived attributes & extensible categorization

Design for an extensible, user-editable categorization system over vault
transactions, and how a question flows from the user through the foundational
model to a final answer. Status: **design / not yet implemented.**

## Why

Today a category question ("how much on phone bills?") is answered by the
generated program calling the on-device model per transaction at *query time*.
That is slow, non-deterministic, and produces the "$224,303 phone bill" class of
error. We want categories (phone, travel, restaurant, groceries, health, …) to
be:

- **extensible** — add more over time with no schema migration,
- **user-editable** — the user can add/adjust their own,
- **consistent & fast** — computed once, reused, no per-query model call,
- **inspectable** — the user can see and control how their data is labeled
  (a fit for a privacy-first product).

## Core concept: derived attributes

A **derived attribute** is a named function over a `Txn`
(`category`, `is_travel`, `merchant_normalized`, `month`, a `tags` list…).
Split them by **cost & determinism**, because that dictates the architecture:

- **Cheap + pure** (rules / regex / arithmetic): e.g. `travel = desc matches
  {airlines, hotels, car-rental}`. Microseconds, deterministic, inspectable.
  Travel / restaurant / groceries / health are almost entirely this kind.
- **Expensive + fuzzy** (ML): `category = classify(desc)` for a merchant no rule
  matches. Slow, non-deterministic → **must be cached**, never recomputed per
  query. Only the long tail needs this.

Model categories as **multi-valued tags** (a txn can be both `travel` and
`restaurant` — an airport meal), not a single category.

## The registry (the extensible mechanism)

A **persisted, user- and model-editable registry** of attribute definitions
(e.g. under `~/.config/millfolio/attributes/`). Each attribute is one of:

- a **rule set** — keyword/regex → value (the common, safe case),
- a **Mojo predicate** — model- or user-authored, for logic rules can't express
  (runs in the existing enclave sandbox; no new trust surface),
- an **ML classifier** — for the fuzzy tail, results cached.

Key principle: **the model writes rules INTO the registry, not into a throwaway
per-query program.** A proposed rule becomes a persisted, named, reviewable,
editable artifact — consistent across queries, improvable over time, and under
user control. Free-form model code each query was rejected: it is
non-deterministic, inconsistent, never accumulates, and is harder to verify.

The registry (attribute names + descriptions) is injected into the codegen
context, like the manifest is today, so the model knows what exists.

## Query flow

1. **User asks a question.**
2. **Model gets the registry** (available attributes + definitions) in its
   codegen context.
3. **Model tries to answer with existing attributes.**
   - If they suffice → **straight to step 5** (the common case; no interruption).
   - Else decide **persist vs. inline**:
     - **One-off / query-specific** slice ("places with 'yoga' in the name") →
       the model writes the predicate **inline** in the query. No registry
       entry, no approval, no backfill.
     - **Reusable** attribute ("travel", "health") → the model **proposes a
       rule + previews what it matches** ("tags these 47 transactions as
       travel"); the user edits / approves.
4. **On approval → persist to the registry + backfill ("backpropagate")** the
   attribute over existing transactions. Cost depends on kind:
   - pure rule → **instant** (no model call),
   - ML-backed → needs the engine up, slower, results cached.
   Future indexing auto-applies every registry rule to new statement rows.
5. **Model generates the final query** (a filter predicate / aggregation)
   against the now-backfilled attribute.
6. **Debug view** — the user sees the records + their tags + the generated code
   + the output, and can **edit a definition → re-backfill → answers update.**
   The preview-before-persist in step 3 is part of this same inspect/edit loop.
7. **(Parallel track) Storage in LanceDB** — see below. The 1–6 loop works on the
   current flat side-table today; LanceDB is the scale + index upgrade, not a
   prerequisite.

## Tag mechanics: mechanism × persistence, and validation

Two **independent** axes govern every tag. Conflating them is the main source of
confusion; keep them separate.

|                          | **Transient** (query-scoped)               | **Stored** (registry + backfilled to `.tags`)        |
| ------------------------ | ------------------------------------------ | ------------------------------------------------------ |
| **Deterministic** (kw/regex) | one-off slice ("names containing 'yoga'") | the default for durable categories (phone, travel)     |
| **ML** (`ask_local` classify) | one-off semantic slice ("felt like impulse buys") | the long tail — **pay the cost once at index, reuse** |

### How codegen decides deterministic vs ML

The model runs this in order:

1. **Does an existing tag cover it?** → `"x" in t.tags`. No interruption (common case).
2. **Is it keyword-able?** — can the model *name* the discriminating merchants from
   world knowledge? `phone → {verizon, at&t, t-mobile, mint, …}` is a closed,
   nameable set → **deterministic**. Only a genuinely semantic boundary no keyword
   list captures (`"business expense"`) → **ML via `ask_local`**.
3. **Durable or one-off?** — a noun-category you'd ask again (phone, groceries) →
   propose a *stored* tag. An ad-hoc slice for this question only → *inline/transient*.

So **"how much on phone"** should propose a deterministic, durable `phone` tag and
validate it — NOT loop `ask_local` per txn (the slow, non-deterministic path that
produced the "$224,303 phone bill"). The codegen system prompt must bias toward
"define a reusable deterministic tag when you can name the merchants." That one
prompt rule is the highest-leverage fix.

**Confidentiality is what makes proposing keywords safe:** the model sees only
aliases, so it picks keywords from *world knowledge* (`verizon` is a phone company),
never from your data. General knowledge comes from the cloud model; the private
specifics (which actually appear in *your* statements, which false-positive) come
from on-device validation. That separation is load-bearing.

### Propose, don't write — and ML in "ingest mode"

The untrusted frontier model must **propose, never write** the registry
(`categories.txt` is a trusted, user-owned, on-device file; a model write is a
privilege escalation, and it can't validate anyway since it can't see real
descriptions). It emits a **structured proposal** `{name, mechanism,
keywords | ml_prompt}`; the trusted on-device layer (`vault.derive.store`) commits
it **after the user approves**.

Extend the registry with a second rule type beside keyword rules: an **ML rule**
= `tag : <classification prompt>`, backfilled at index time by batched
`ask_local` over each txn into the same `.tags` column. The slow cost is paid
**once per statement at ingest**; every later query is a free exact filter,
identical downstream to a deterministic tag. ML+transient stays the one-off escape
hatch; ML+stored is the new capability the model can propose.

### The validation workflow (chat UI, on the existing `WorkflowPanel`)

Triggered when the model proposes a new tag, or the user edits a definition:

1. **Announce** — a workflow step: "New tag `phone` — validate before saving",
   showing the proposed definition.
2. **Dry-run, time-boxed.** Run the candidate on-device over a sample. Deterministic
   → near-instant over all txns; ML → `ask_local` over a **stratified** sample
   (clear positives, clear negatives, and the **boundary/low-confidence** cases)
   within a **~20s budget**, reporting coverage ("validated 40 of 312").
3. **Show stats + examples.** Match rate, **positive examples**, and — most
   important — likely **errors**: false positives (the Chase "Crd Epay …3934444444"
   surfaces here as a `phone` match to reject) and false negatives (unmatched txns
   that look phone-related → a missing keyword).
4. **Edit → loop.** User tweaks keywords / the ML prompt → re-run step 2. On
   **Approve** → `save_categories` + re-tag (instant for deterministic; backfill via
   `ask_local` for ML).

**Hard constraint:** past the proposal the loop is **on-device only**. Dry-run
results (matched descriptions, false positives) must **never** go back to the
frontier model — that would leak exactly the data we alias. Refinement is the user
+ optionally the trusted local model, which (seeing real text) can *suggest* missing
keywords the frontier model couldn't safely give.

## ML backfill: ledger, incremental worker, and controls

An ML rule (`<tag> : <question>`) is expensive — a model call per transaction — so
its results are **backfilled once and cached** in the `.tags` column, then reused
as a fast exact filter. This section specs how that backfill is tracked,
run incrementally, made observable, and controlled (cancel / pause).

Today's `ml_backfill` just re-scans "rows missing this tag" each run, which
**conflates "not yet evaluated" with "evaluated → no"** — so it can't tell what's
left, and it re-does the engine work for every true-negative. The fix is a decision
ledger.

### Invariants (design contract — do not violate)

1. **Ledger-is-a-cache.** The ledger is a rebuildable OPTIMIZATION, never a source
   of truth. Truth = `categories.txt` (rules) + `transactions.tsv` (records +
   `.tags`). Any ledger loss/corruption degrades EFFICIENCY (re-do some work),
   never CORRECTNESS.
2. **Single flock.** All ledger + `.tags` writes serialize through ONE advisory
   `flock` (the run-queue discipline). Reads (the status UI) are lock-free and
   tolerate a slightly stale count.
3. **No lock across the engine call.** Classify the batch UNLOCKED (the slow,
   possibly-hanging part), then take the lock only for the fast append. Holding the
   lock across a hung engine would stall every other writer.
4. **Atomic rewrites.** Full rewrites (cancel-purge, compaction) write `*.tmp`,
   `fsync`, `rename()` — a crash leaves the whole old or whole new file, never a mix.
5. **Skip-malformed on read.** Parse the ledger line-by-line; drop any unparseable
   line (a truncated tail from a crashed append just re-queues those pairs).
6. **Idempotent re-classify.** Re-classifying a row that already carries the tag
   yields the same verdict → no drift. So delete-and-rebuild is always safe.

### The ledger — a per-rule completion marker keyed on insertion generation

The naive "one row per (transaction × rule)" ledger is quadratic and, worse,
stores a row per TRUE NEGATIVE — the common case ("I don't have a gym" → every
txn a `no` row). Collapse it to **one marker per rule** by keying coverage on a
monotonic **insertion generation**, not the transaction's date.

**`added_gen` — a monotonic insertion counter.** Every transaction gets an
`added_gen` assigned at index time from a persisted counter (next to the
manifest's `next_id`/`next_alias`), incremented as rows are appended. It records
INSERTION ORDER, decoupled from the transaction's `date`. This is the crux: a
back-dated statement indexed today gets a HIGH `added_gen` (it was inserted late)
→ correctly seen as pending, even though its date is old. A date high-water-mark
would silently skip it — wrong.

**Re-index reconciliation — unchanged rows keep their generation.** A full
re-index (an explicit `--force`, an index-processing-version bump, or a changed
source dir) re-extracts EVERY transaction and would otherwise stamp each with a
fresh, higher `added_gen`, leaving them all `> done_gen` → the ledger would treat
the entire vault as pending and re-run the whole ML backfill (thousands of model
calls) even though nothing changed. To prevent this, `build_index` snapshots the
previously-stored rows and, after re-extraction, calls
`reconcile_txn_gens(new, prev)`: a freshly-extracted row whose content fingerprint
(`date + year + desc + amount + direction` — file-independent) matches a prior row
REUSES that row's `added_gen` and cached tags. Matched with multiplicity (each
prior row reused once). So an unchanged row keeps its old generation `<= done_gen`
→ skipped; a genuinely new / changed row keeps the fresh generation → pending →
classified. This is why `next_gen` is NOT reset on a full rebuild — it must stay
monotonic so a new row added during the rebuild still lands ABOVE `done_gen`. The
inline index-time ML pass (`ml_backfill_rows`) is also handed the ledger, so it
skips any row already covered even when a full rebuild puts every file in its
"newly-embedded" set.

**The marker — `~/.config/millfolio/ml_ledger.tsv`**, header `# ml_ledger v1`
(format versioning → discard + rebuild on mismatch). One line per ML rule:

```
rule   qhash   done_gen
gym    9f3a    412
café   1b7e    412
```

- **`qhash`** — short hash of the rule's question. Editing `is this a gym?`
  changes `qhash` → the marker no longer matches → that rule (only) fully
  re-backfills from `done_gen = 0`.
- **`done_gen`** — rule R is backfilled for every row with
  `added_gen <= done_gen` at this `qhash`. **Pending = rows with
  `added_gen > done_gen`** (or a stale/absent `qhash`). After a pass completes,
  `done_gen = max(added_gen)`.

**Negatives are IMPLICIT** — the marker covers the whole `added_gen <= done_gen`
range; positives live in `.tags`, everything else in-range is a backfilled
negative. So the mostly-negative case costs **O(1) per rule**, no per-negative
rows. The durable footprint is a handful of marker lines, regardless of vault
size.

**The queue is DERIVED, not stored:** for each active ML rule, the pending set is
`{ rows : added_gen > done_gen(rule, cur_qhash) }`. Nothing to keep in sync;
self-heals after a crash mid-batch (a partial pass just leaves `done_gen` behind
the true max → the tail re-queues). Mid-pass resume needs only a cursor, not
per-txn rows: advance `done_gen` in-marker as batches commit.

**Migration.** Pre-existing rows (written before `added_gen`) default to
`added_gen = 0`; markers start absent (treated as `done_gen = -1`) → on first run
EVERYTHING is pending and backfills exactly once, after which the marker
tracks only the delta. Ledger loss re-backfills (negatives are derived facts —
unavoidable), but that's a bounded one-time cost; the invariant holds:
**ledger-is-a-cache.**

### The controller — runtime state

Tiny `~/.config/millfolio/backfiller.json` holding ONLY control/observability
state (anything derivable — progress, ETA — is computed from the ledger, not
stored):

```json
{ "status": "idle|running|paused", "paused_until": 0,
  "current_rule": "gym", "throughput_ms_per_batch": 1800, "last_error": "" }
```

### The incremental worker

- After each answered question (or on an idle tick): if `now >= paused_until` and
  `pending > 0`, take the batch of the next pending rule (~16 txns, `ML_BATCH`),
  classify UNLOCKED via `classify_batch`, then under the flock set `.tags` for the
  yeses + advance the rule's `done_gen` past the batch. Bounded → always yields to
  the next real question.
- The app-server slice uses a **non-blocking try-lock** (skip this tick if the CLI
  holds it) so it can never delay a question.
- `millfolio backfill` (CLI) drains the whole queue in one go; honors
  `paused_until` too.
- Progress is durable (the ledger), so pause/resume/crash all resume exactly where
  they stopped.

### Codegen readiness gate (the correctness tie-in)

An ML tag advertised to codegen but NOT yet backfilled is a hazard: codegen
filters `"gym" in t.tags` → empty `.tags` → false "no gym spending." So:

- A rule is **ready** iff `done_gen >= max(added_gen)` at the current `qhash`
  (its marker covers every inserted row).
- **Ready** → advertise it in the codegen tag list normally (fast filter).
- **Pending** → advertise as `gym (pending)` (or withhold it) so codegen classifies
  INLINE meanwhile, exactly like the first time it was asked.

So backfill is what flips a tag from "classify inline each time" → "fast
exact filter," and the gate falls out of the ledger for free.

### Operations

- **Work-left estimate** — per tag: `evaluated = #{rows : added_gen <= done_gen}`
  at the current `qhash`, `total = #transactions`, `pending = total − evaluated`,
  plus the `.tags` yes count → a progress bar + "N left".
  ETA = `pending / ML_BATCH × throughput_ms_per_batch` (the controller keeps
  a rolling throughput, so the ETA tracks real engine speed).
- **Cancel a tag + its remaining work** — because the queue is derived from ACTIVE
  rules, removing the rule from `categories.txt` drops its pending set from the
  queue instantly (no in-flight cancellation bookkeeping). Then drop its marker
  line (`rule == gym`, atomic rewrite) and strip `gym` from `.tags`. The
  keep-partial variant is a per-rule `enabled:false` flag — excluded from the
  active/pending set, existing decisions + tags retained.
- **Pause for a time** — set `paused_until = now + duration`. Every worker checks it
  first and no-ops while paused; **auto-resumes** when it elapses (Resume sets it to
  0). Free, because progress lives in the ledger.

### UI + endpoints

A **Backfill panel** (Tags tab, or a small Activity area): overall
status + a pause control (duration → "paused for 42 min" + Resume) + **Backfill
now**; per AI tag a progress bar (`38/152 · 25%`), ready/pending badge, yes/no
counts, and a **Cancel** (×) button; footer with total pending + ETA. Backed by:

- `GET  /api/backfill/status` — `{status, paused_until, perTag:[{tag,question,
  total,evaluated,pending,yes,ready}], pendingTotal}` (lock-free read; backs
  `millfolio backfill --status`).
- `POST /api/backfill/pause {seconds}` / `.../resume`
- `POST /api/backfill/run` — kick a bounded slice / drain.
- tag cancel — the existing category delete (editor save) reconciles the ledger:
  `save_categories` drops the marker of any rule no longer an active ML rule, and
  the retag pass strips its `.tags`.

### Build order (each shippable on its own) — STATUS

1. ✅ **Readiness gate** — `store.codegen_tags_describe()` withholds an
   un-backfilled ML tag from `millfolio tags --describe`, so codegen never
   filters `.tags` on it and returns a false empty.
2. ✅ **Decision ledger** (`derive/ledger.mojo`, pure + unit-tested) + rewrite
   `ml_backfill` to drain the queue from `added_gen > done_gen` incrementally
   (each true negative classified once), under the advisory lock, classify outside
   nothing that spans a held lock across writers. `ledger_note_backfilled`
   advances markers after the index-time inline pass so routine re-indexes don't
   redo a generation.
3. ✅ **Status / pause** endpoints + the Backfill UI panel + the
   between-questions worker slice (`ml_backfill_slice`, try-lock, pause-aware).

## Storage

### Today (flat TSV side-tables)

`mill index` (`core/src/vault/index/index.mojo`, `build_index`) writes under
`~/.config/millfolio/`:

- `index.db/` — LanceDB vector store (table `chunks`, dim 1024) for semantic
  search.
- `chunks.tsv` — `chunk_id ⇥ file_alias ⇥ escaped_text` (backs `file_chunks()`).
- `manifest.tsv` — per-file metadata; the `#meta` line carries `next_id`,
  `next_alias`, `source_dir`, and **`next_gen`** (the monotonic insertion-generation
  counter the ML ledger keys on).
- **`transactions.tsv`** — one row per **reconciled** transaction:
  `TxnRow(falias, date, amount, direction, desc, tags, added_gen, year)` (TSV =
  tab-separated; tabs chosen because descriptions contain commas, and any literal
  tab/newline is escaped). Trailing columns are append-only for back-compat: legacy
  5-col rows parse with no tags, 6-col rows as `added_gen = 0`, 7-col rows as
  `year = 0`. `date` is the raw `M/D` the statement prints; `year` is the statement
  year detected once per document (`statement_year`, 0 = unknown). Extracted **once
  at index time**, only kept when it reconciles against the statement's own
  arithmetic. Incremental: load → drop changed aliases → re-extract changed → rewrite.
- **`ml_ledger.tsv`** — the ML-backfill completion markers
  (`# ml_ledger v1`, one `rule ⇥ qhash ⇥ done_gen` line per ML rule). A CACHE, not
  truth (see the ML-backfill section). Guarded by a `mkdir`-based advisory
  lock (`ml_ledger.lock`).
- `backfiller.json` — the controller/pause state (`{status, paused_until}`).

Read path: `transactions(alias)` → `index.file_transactions(alias)` →
in-memory filter. No model call; already exact.

A derived attribute is, in this model, **a generic `(txn, attribute_name) →
value` side-table** (e.g. `derived.tsv`) keyed by a stable txn hash — so new
attributes need **no schema migration** and a txn can carry many tags.
Backfilled at index time / backfilled when a rule changes; ML results cached.

### Why TSV today (not a LanceDB limitation)

1. **The Mojo binding is vector-only.** `lancedb.mojo` is a thin C-FFI over a
   Rust shim (`lancedb.mojo/ffi/src/lib.rs`, lancedb crate 0.30) that
   **hardcodes** the schema to `id: Int64 + vector: FixedSizeList<Float32,
   dim>`. Exposed surface: `add(ids, vectors)`, `search(vector, k)`,
   `delete(predicate)`, `count`, `optimize`, `create_index`. There is **no API**
   for arbitrary-schema tables, scalar rows, SQL/filter scans returning rows, or
   merge/update.
2. **Scale doesn't demand it.** Hundreds–low-thousands of rows per user; a
   linear in-memory filter is microseconds. TSV is also trivially
   inspectable/editable/diffable (a virtue here) and composes with the existing
   incremental diff.

### When LanceDB becomes the right answer

LanceDB is **more than vectors** — it's Lance (columnar) + Arrow + DataFusion:

- tables with **no vector column** (pure structured rows),
- **scalar indexes** that map onto categorization exactly: **BITMAP** (docs:
  ideal for "few unique values — categories, tags"), **LABEL_LIST** (`List<T>`
  with `array_contains_all/any` — purpose-built for multi-valued **tags**),
  BTREE (amount/date),
- **filter pushdown + projection** via DataFusion,
- **merge-insert / update** for incremental attribute refresh,
- full-text (BM25) + hybrid search.

**DataFusion nuance:** it *is* incorporated as Lance's embedded execution engine
(the scanner builds DataFusion physical plans; the `lancedb` crate pulls
`datafusion`). But the **open-source API exposes filter expressions +
projection**, not a general `SELECT … GROUP BY`. Full SQL (FlightSQL) is
**Enterprise-only**. So for our embedded shim the free win is **indexed,
pushed-down filtering** (`tags array_contains 'phone'`), with the **sum/count
done in Mojo over the small filtered result** — or by wiring a DataFusion
`SessionContext` ourselves if we later want server-side aggregation.

**Cost:** moving transactions + derived attributes into LanceDB requires
**extending the Rust FFI shim + the Mojo binding** (arbitrary-schema table,
insert, filter-scan returning scalar rows, merge-insert, scalar/bitmap indexes).
That is the real work; it's worth it once the derived-attribute system implies
many tags, indexed filtering, and a clean `WHERE`-predicate codegen target.

**Avoid the middle ground** of keeping TSV as source-of-truth *and* a LanceDB
query copy — two stores to keep in sync. Pick one.

## Open decisions

- **Approval UX / latency:** block the answer on approval for *persisted*
  attributes (they shape every future answer), never block for *inline*
  one-offs. Confirmed direction; finalize the UI.
- **Tags vs single category:** tags (multi-valued). Confirmed direction.
- **Seed taxonomy + rule format:** start with a keyword-list format (TOML?), and
  decide whether to allow regex / Mojo predicates from day one.
- **ML-at-index-time vs lazy:** deterministic rules at index time; ML tail either
  (a) requires the engine during `mill index`, or (b) a lazy
  "categorize-the-uncategorized" pass when the engine is up. Lean lazy.
- **CSV path:** confirm CSV statements actually land in `transactions.tsv`
  (`build_index` skips the layout re-extract for `csv` — "already structured");
  verify before relying on it for categorization.
- **Storage migration timing:** keep 1–6 on the flat side-table; schedule the
  LanceDB binding extension as a separate track (before or after the registry
  loop).
