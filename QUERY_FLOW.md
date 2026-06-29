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
  (runs in the existing privacy_box sandbox; no new trust surface),
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
   against the now-materialized attribute.
6. **Debug view** — the user sees the records + their tags + the generated code
   + the output, and can **edit a definition → re-backfill → answers update.**
   The preview-before-persist in step 3 is part of this same inspect/edit loop.
7. **(Parallel track) Storage in LanceDB** — see below. The 1–6 loop works on the
   current flat side-table today; LanceDB is the scale + index upgrade, not a
   prerequisite.

## Storage

### Today (flat TSV side-tables)

`mill index` (`core/src/vault/index/index.mojo`, `build_index`) writes under
`~/.config/millfolio/`:

- `index.db/` — LanceDB vector store (table `chunks`, dim 1024) for semantic
  search.
- `chunks.tsv` — `chunk_id ⇥ file_alias ⇥ escaped_text` (backs `file_chunks()`).
- `manifest.tsv` — per-file metadata.
- **`transactions.tsv`** — one row per **reconciled** transaction:
  `TxnRow(falias, date, amount, direction, desc)` (TSV = tab-separated; tabs
  chosen because descriptions contain commas, and any literal tab/newline is
  escaped). Extracted **once at index time**, only kept when it reconciles
  against the statement's own arithmetic. Incremental: load → drop changed
  aliases → re-extract changed → rewrite.

Read path: `transactions(alias)` → `index.file_transactions(alias)` →
in-memory filter. No model call; already exact.

A derived attribute is, in this model, **a generic `(txn, attribute_name) →
value` side-table** (e.g. `derived.tsv`) keyed by a stable txn hash — so new
attributes need **no schema migration** and a txn can carry many tags.
Materialized at index time / backfilled when a rule changes; ML results cached.

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
