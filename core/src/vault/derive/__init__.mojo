"""Vault.derive — derived attributes over extracted transactions.

A *derived attribute* is a named function over a transaction (tags like
`phone`/`travel`/`restaurant`, a normalised merchant, a month, …). This package
holds the extensible, user-editable mechanism that computes them — starting with
the deterministic, dependency-free tag matcher (`categorize`).

See `QUERY_FLOW.md` (vault root) for the full design: a persisted registry of
rules (cheap/pure) + an ML tail (cached), materialised once and queried, instead
of a per-question model call.
"""

from vault.derive.categorize import (
    Rule,
    Registry,
    default_registry,
    parse_rules,
    merge_registry,
    tag_names,
    rules_canon,
    registry_to_text,
)
