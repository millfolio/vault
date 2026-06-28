"""Vault — the precompiled tool-surface package a privacy_box-generated program
imports via `from vault import *`.

This `__init__` is the package's public face: it re-exports the entire tool
surface from `vault.tools` plus the public types those tools return, so the
`from vault import *` contract (used verbatim in privacy_box-system.md and every
example) resolves unchanged whether the package is consumed as source or as a
precompiled `vault.mojopkg`.

The tool surface (signatures + semantics) is documented in `vault/tools.mojo`
and must match privacy_box/resources/privacy_box-system.md exactly.
"""

# The full tool surface (manifest/search/csv_rows/pdf_text/md_text/docx_text/
# ask_local/ask_local_batch/print_answer/progress/iso_date/parse_amount + the
# VaultFile view + the PROGRESS/STAT sentinels).
from vault.tools import *

# Public types a generated program names through tool return values:
#   search(...) -> List[Chunk]      (Chunk.file_alias / .text / .score)
#   manifest()  -> List[VaultFile]  (re-exported transitively by `tools`, but
#                                    name it explicitly so it's unambiguous)
from vault.index import Chunk
from vault.tools import VaultFile
from vault.extract import Txn
