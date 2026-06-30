"""Vault.index — indexing, manifest, readers, embeddings, and content hashing.

Re-exports the public surface of its modules so `from vault.index import …` and
`vault.index.name` resolve from anywhere (source or precompiled `.mojoc`).
"""

from vault.index.index import (
    build_index,
    search,
    file_chunks,
    file_transactions,
    vault_files,
    index_manifest,
    Chunk,
)

# The registry/tags/retag store is LanceDB-free (vault.derive.store) and shared
# with the app server; re-exported here so existing `vault.index` callers (the
# CLI) keep their imports.
from vault.derive.store import (
    effective_tags,
    effective_retag,
    ml_materialize,
    tags_report,
    tags_report_json,
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
