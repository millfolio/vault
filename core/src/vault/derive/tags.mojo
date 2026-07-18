"""Tags — the on-device tag-registry READ layer (categories.txt + readiness).

Split out of `store.mojo` so it can be shared IN-PROCESS by every consumer,
including the enclave harness, WITHOUT dragging the mutate layer
(`classify`/`retag`/backfill — which links flare's HTTP client) into the
privacy sandbox binary. This module depends only on `categorize`, `ledger`, and
the `TxnRow` TSV round-trip (all LanceDB-free and network-free), so importing it
never pulls the engine/HTTP surface.

`store.mojo` imports these back for its mutate paths, so the dependency is
one-directional (store → tags); nothing here calls into `store`.

`categories.txt` is the SOURCE OF TRUTH for the registry (seeded with the
built-in defaults, see `vault.derive.categorize`); the `.tags` column of
`transactions.tsv` + the `ml_ledger.tsv` completion markers back the ML-tag
readiness gate.
"""

from std.os import getenv, makedirs
from std.os.path import exists

from vault.extract.transactions import TxnRow, tsv_to_txn_rows
from vault.index.sha256 import sha256_hex
from vault.derive.categorize import (
    Registry,
    default_registry,
    parse_rules,
    tag_names,
    tag_descriptions,
    rules_canon,
    registry_to_text,
)
from vault.derive.ledger import (
    RuleMarker,
    qhash,
    is_ready,
    parse_ledger,
    marker_done_gen,
    GEN_ABSENT,
)

# The doc-store seam (`vault.storage`, Phase 2 slice B2): categories.txt read/write
# routes through the shared `DocStore` so the on-disk format is swappable (→ SQLite)
# without touching the registry logic here. `vault.storage` is acyclic (stdlib + flare
# only), so importing it never pulls the engine/HTTP surface this module avoids.
from vault.storage import default_categories_store, DOC_CATEGORIES


# ── paths ─────────────────────────────────────────────────────────────────────


def config_dir() raises -> String:
    """The on-device DATA dir — the index, extracted transactions, category rules,
    backfill ledger, and usage/history stores. macOS-native home (matches the
    install tree + keeps financial data out of a dotfiles-synced `~/.config`);
    `MILLFOLIO_DATA_DIR` overrides it (the demo / tests pin their own)."""
    var d = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    if d != "":
        return d
    return getenv("HOME", ".") + "/Library/Application Support/Millfolio/data"


def ensure_data_dir() raises:
    """Create the data dir if it doesn't exist yet (a fresh location simply starts
    empty — there is no migration from the old `~/.config/millfolio`). Best-effort so
    it never crashes a write path."""
    try:
        makedirs(config_dir(), exist_ok=True)
    except:
        pass


def txns_path() raises -> String:
    return config_dir() + "/transactions.tsv"


def categories_path() raises -> String:
    return config_dir() + "/categories.txt"


def ledger_path() raises -> String:
    return config_dir() + "/ml_ledger.tsv"


# ── transactions side-table read + ledger read ─────────────────────────────────


def load_txn_rows() raises -> List[TxnRow]:
    if not exists(txns_path()):
        return List[TxnRow]()
    var text: String
    with open(txns_path(), "r") as f:
        text = f.read()
    return tsv_to_txn_rows(text)


def load_ledger() raises -> List[RuleMarker]:
    if not exists(ledger_path()):
        return List[RuleMarker]()
    var text: String
    with open(ledger_path(), "r") as f:
        text = f.read()
    return parse_ledger(text)


# ── registry (categories.txt is the source of truth) ──────────────────────────


def _sha_str(s: String) -> String:
    """Hex SHA-256 of a string's bytes."""
    var b = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        b.append(p[i])
    return sha256_hex(b)


def _extract_checksum(text: String) raises -> String:
    """The value of the `# managed-checksum:` line, or "" if there is none."""
    var lines = text.split("\n")
    for i in range(len(lines)):
        var ln = String(lines[i].strip())
        if ln.startswith("# managed-checksum:"):
            return String(ln.removeprefix("# managed-checksum:").strip())
    return String("")


def write_categories(path: String, text: String):
    """Best-effort write of the categories file — never fail over it. The write routes
    through the shared `DocStore`; `path` is retained for call-site compatibility and
    always equals the store's resolved `<data-dir>/categories.txt`, so it's
    byte-identical to the previous inline `open(path, "w")`."""
    try:
        ensure_data_dir()
        default_categories_store().save(DOC_CATEGORIES, text)
    except:
        pass


def load_registry() raises -> Registry:
    """The effective tag registry. `categories.txt` is the SOURCE OF TRUTH: it's
    seeded with the real built-in defaults (as editable rules) on first run, and
    the loader honors it verbatim — so the user can edit, remove, or add anything.

    `# managed-checksum:` records the rules we last wrote. If the file's rules
    still hash to it (UNTOUCHED), the defaults auto-refresh on upgrade; once the
    user edits a rule the checksum diverges and the file becomes authoritative —
    we never overwrite it. A legacy/commented/empty file (no checksum, no rules)
    is (re)seeded so it never yields an empty registry."""
    var path = categories_path()
    var defaults = default_registry()
    var seed_sum = _sha_str(rules_canon(defaults))

    if not exists(path):
        write_categories(path, registry_to_text(defaults, seed_sum))
        return defaults^

    var text = default_categories_store().load(DOC_CATEGORIES)
    var user = Registry(parse_rules(text))
    var stored_sum = _extract_checksum(text)

    # Untouched managed file → its rules still hash to the checksum we wrote.
    if (
        stored_sum.byte_length() > 0
        and _sha_str(rules_canon(user)) == stored_sum
    ):
        if stored_sum != seed_sum:
            # Defaults improved this version and the user hasn't edited → refresh.
            write_categories(path, registry_to_text(defaults, seed_sum))
        return defaults^

    # No managed checksum AND no active rules = the legacy commented template (or
    # an emptied file) → the user hasn't defined anything, so seed the defaults.
    if stored_sum.byte_length() == 0 and len(user.rules) == 0:
        write_categories(path, registry_to_text(defaults, seed_sum))
        return defaults^

    # Otherwise the user has made it their own → the file is authoritative.
    return user^


def read_categories() raises -> String:
    """The raw `categories.txt` text for the editor — seeds the file first (via
    the loader's side effect) so it's never empty/missing."""
    _ = load_registry()  # seed/refresh if needed
    var path = categories_path()
    if not exists(path):
        return String("")
    return default_categories_store().load(DOC_CATEGORIES)


# ── tag names + ML readiness ───────────────────────────────────────────────────


def effective_tags() raises -> List[String]:
    """The tag NAMES the effective registry can assign — what `millfolio tags`
    prints and codegen advertises to the model so it can filter `transactions()`
    on `.tags`, including the user's own categories."""
    return tag_names(load_registry())


def effective_tag_descriptions() raises -> List[String]:
    """Per-tag scope notes, parallel to `effective_tags()` (empty when none) —
    sent to codegen alongside the names so the model picks the right tag."""
    return tag_descriptions(load_registry())


def contains(xs: List[String], s: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == s:
            return True
    return False


def max_added_gen(rows: List[TxnRow]) -> Int:
    var m = GEN_ABSENT
    for i in range(len(rows)):
        if rows[i].added_gen > m:
            m = rows[i].added_gen
    return m


def ml_ready_tags() raises -> List[String]:
    """The ML-rule tag names that are fully backfilled at their current question
    hash — safe for codegen to advertise as an exact `.tags` filter. A pending /
    stale rule is withheld (see `codegen_tags_describe`) so a `"gym" in t.tags`
    filter can never return a false empty over un-classified rows."""
    var reg = load_registry()
    var rows = load_txn_rows()
    var markers = load_ledger()
    var max_gen = max_added_gen(rows)
    var out = List[String]()
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if not r.is_ml():
            continue
        var cur = qhash(r.ml_prompt)
        var mdg = marker_done_gen(markers, r.tag, cur)
        if is_ready(cur, mdg, cur, max_gen):
            out.append(r.tag.copy())
    return out^


def codegen_tags_describe() raises -> String:
    """`name <TAB> description` per line for the CODEGEN prompt (the readiness
    gate): every deterministic tag, plus only the ML tags that are fully
    backfilled. Withholding a pending ML tag makes codegen classify inline (or
    skip it) rather than filter an empty `.tags` and report a false "no X". Backs
    `millfolio tags --describe`."""
    var reg = load_registry()
    var ready = ml_ready_tags()
    var out = String("")
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if r.is_ml() and not contains(ready, r.tag):
            continue  # pending / stale ML rule → withhold from the fast filter
        out += r.tag + "\t" + r.description + "\n"
    return out^
