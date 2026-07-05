"""Vault.index — indexing, manifest, readers, embeddings, and content hashing.

Re-exports the public surface of its modules so `from vault.index import …` and
`vault.index.name` resolve from anywhere (source or precompiled `.mojoc`).
"""

from vault.index.index import (
    build_index,
    index_one_file,
    finalize_index,
    FileStepResult,
    search,
    file_chunks,
    file_transactions,
    vault_files,
    index_manifest,
    Chunk,
)

# The tag-registry READ layer (vault.derive.tags — LanceDB- and network-free) and
# the mutate/report layer (vault.derive.store) are shared in-process with the app
# server and privacy_box; re-exported here so existing `vault.index` callers keep
# their imports, each from the module that DEFINES it.
from vault.derive.tags import (
    effective_tags,
    effective_tag_descriptions,
    codegen_tags_describe,
    ml_ready_tags,
)
from vault.derive.store import (
    effective_retag,
    ml_backfill,
    ml_backfill_slice,
    ledger_note_backfilled,
    backfill_status_json,
    set_pause,
    is_paused,
    tags_report,
    tags_report_json,
    transactions_json,
    TagInfo,
)
from vault.index.manifest import build_manifest, FileInfo, _csv_columns
from vault.index.readers import (
    csv_rows,
    md_text,
    pdf_text,
    pdf_text_layout,
    docx_text,
)
from vault.index.embed import embed, embed_batch, EMBED_DIM
from vault.index.sha256 import sha256_file_hex, sha256_hex
