"""Vault.storage — the swappable on-disk persistence seam (the `Store` layer).

INTERNAL infra, NOT part of the `from vault import *` tool surface: it is importable
only by name, `from vault.storage import …`. It holds the per-shape store traits
(`QueueStore` / `LogStore` / `KvStore` / `DocStore` — all four shapes) with their
file-backed implementations (`FileQueueStore` / `FileLogStore` / `FileKvStore` /
`FileDocStore`), the plain records the queue moves (`WorkItem` / `QueueState` / the
`PRIO_*` defaults), and the `default_*_store()` factories that are the single Phase-5
SQLite swap points.

Promoted here from `app/server` (Phase 2 slice B1) so both the app server AND the
vault-side registries share one `Store` definition + one future `SqliteStore` backend.
Self-contained: depends only on stdlib + the `flare` sibling lib, NOTHING from
`app/server`. Design + migration roadmap: `app/server/STORAGE.md`.
"""

from vault.storage.storage import (
    # ── records + priority defaults (queue) ──
    WorkItem,
    QueueState,
    PRIO_INDEX,
    PRIO_FINALIZE,
    PRIO_BACKFILL,
    # ── queue store ──
    QueueStore,
    FileQueueStore,
    default_queue_store,
    work_queue_path,
    # ── append-log stores ──
    LogStore,
    FileLogStore,
    default_operations_store,
    default_stats_store,
    default_asks_store,
    default_millwright_versions_store,
    operations_log_path,
    stats_log_path,
    asks_log_path,
    millwright_log_path,
    millwright_dir,
    # ── KV / small-marker store ──
    KvStore,
    FileKvStore,
    default_kv_store,
    KV_INDEX_STATE,
    KV_INDEX_PID,
    KV_INDEX_OP,
    KV_INDEX_RUNTOTAL,
    KV_DEMO_STATE,
    KV_DEMO_OP,
    KV_DL_STATE,
    KV_DL_MODEL,
    KV_MILLWRIGHT_ACTIVE,
    # ── doc store (whole-document rewrite) ──
    DocStore,
    FileDocStore,
    default_categories_store,
    default_manifest_store,
    default_indexed_paths_store,
    default_millwright_docs_store,
    DOC_CATEGORIES,
    DOC_MANIFEST,
    DOC_INDEXED_PATHS,
    # ── persisted-path portability (write ~-relative, read both forms) ──
    contract_home,
    expand_home,
)
