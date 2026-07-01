"""Store — the on-device derived-attribute store + registry I/O.

The `~/.config/millfolio/` files that back categorization: `categories.txt` (the
tag registry — SOURCE OF TRUTH, seeded with the built-in defaults, see
`vault.derive.categorize`) and the `.tags` column of `transactions.tsv`.

This module is deliberately **LanceDB-free** (it touches only those two files +
pure helpers), so BOTH the `millfolio` CLI and the app server import it and call
the SAME functions in-process — no spawning a separate engine binary for tags /
retag / category edits. The heavy index/embedding work stays in `vault.index`.
"""

from std.os import getenv
from std.os.path import exists

from vault.extract.transactions import TxnRow, tsv_to_txn_rows, txn_rows_to_tsv
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
from vault.derive.classify import classify_batch


# ── paths ─────────────────────────────────────────────────────────────────────


def config_dir() raises -> String:
    return getenv("HOME", ".") + "/.config/millfolio"


def txns_path() raises -> String:
    return config_dir() + "/transactions.tsv"


def categories_path() raises -> String:
    return config_dir() + "/categories.txt"


# ── transactions side-table I/O ───────────────────────────────────────────────


def load_txn_rows() raises -> List[TxnRow]:
    if not exists(txns_path()):
        return List[TxnRow]()
    var text: String
    with open(txns_path(), "r") as f:
        text = f.read()
    return tsv_to_txn_rows(text)


def write_txn_rows(rows: List[TxnRow]) raises:
    with open(txns_path(), "w") as f:
        f.write(txn_rows_to_tsv(rows))


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


def _write_categories(path: String, text: String):
    """Best-effort write of the categories file — never fail over it."""
    try:
        with open(path, "w") as f:
            f.write(text)
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
        _write_categories(path, registry_to_text(defaults, seed_sum))
        return defaults^

    var text: String
    with open(path, "r") as f:
        text = f.read()
    var user = Registry(parse_rules(text))
    var stored_sum = _extract_checksum(text)

    # Untouched managed file → its rules still hash to the checksum we wrote.
    if (
        stored_sum.byte_length() > 0
        and _sha_str(rules_canon(user)) == stored_sum
    ):
        if stored_sum != seed_sum:
            # Defaults improved this version and the user hasn't edited → refresh.
            _write_categories(path, registry_to_text(defaults, seed_sum))
        return defaults^

    # No managed checksum AND no active rules = the legacy commented template (or
    # an emptied file) → the user hasn't defined anything, so seed the defaults.
    if stored_sum.byte_length() == 0 and len(user.rules) == 0:
        _write_categories(path, registry_to_text(defaults, seed_sum))
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
    var text: String
    with open(path, "r") as f:
        text = f.read()
    return text^


def save_categories(text: String) raises -> Int:
    """Overwrite `categories.txt` with the editor's content (this makes the file
    'touched' → authoritative) and re-tag the stored transactions. Returns the
    number of transactions whose tags changed."""
    _write_categories(categories_path(), text)
    return effective_retag()


# ── tags: names, materialization, report ──────────────────────────────────────


def effective_tags() raises -> List[String]:
    """The tag NAMES the effective registry can assign — what `millfolio tags`
    prints and codegen advertises to the model so it can filter `transactions()`
    on `.tags`, including the user's own categories."""
    return tag_names(load_registry())


def effective_tag_descriptions() raises -> List[String]:
    """Per-tag scope notes, parallel to `effective_tags()` (empty when none) —
    sent to codegen alongside the names so the model picks the right tag."""
    return tag_descriptions(load_registry())


def _tags_equal(a: List[String], b: List[String]) -> Bool:
    """Order-sensitive tag-list equality (tags_for is deterministic in registry
    order, so a positional compare is enough)."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _contains(xs: List[String], s: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == s:
            return True
    return False


def retag(mut rows: List[TxnRow], reg: Registry) raises -> Int:
    """Re-apply the registry's DETERMINISTIC tags to every stored transaction in
    place (pure — no model call, no re-embed), PRESERVING any ML-rule tags already
    materialized on the row. `tags_for` is deterministic-only (an ML rule never
    matches by keyword), so without the carry-over a plain re-tag would strip the
    ML tags that were assigned, at index time, with a model call. Returns the
    COUNT of rows whose tags changed, so callers persist only when something
    moved — this is what makes a plain `mill index` re-tag after the user edits
    categories.txt, instead of a forced re-embed."""
    var ml = List[String]()  # the registry's ML-rule tag names (preserved)
    for i in range(len(reg.rules)):
        if reg.rules[i].is_ml():
            ml.append(reg.rules[i].tag.copy())
    var changed = 0
    for i in range(len(rows)):
        var new_tags = reg.tags_for(
            rows[i].desc
        )  # deterministic, registry order
        # Carry over any ML tag already on the row (it was a model call to compute,
        # cached here — re-materialized only at index time for new transactions).
        for g in range(len(rows[i].tags)):
            ref t = rows[i].tags[g]
            if _contains(ml, t) and not _contains(new_tags, t):
                new_tags.append(t.copy())
        if not _tags_equal(rows[i].tags, new_tags):
            var r = rows[i].copy()
            r.tags = new_tags^
            rows[i] = r^
            changed += 1
    return changed


def effective_retag() raises -> Int:
    """Re-apply the current registry to the stored transactions and persist —
    standalone (no file scan, no embedding). Backs `millfolio retag` and the app
    server's category save. Returns the number of rows changed."""
    var reg = load_registry()
    var trows = load_txn_rows()
    var changed = retag(trows, reg)
    if changed > 0:
        write_txn_rows(trows)
    return changed


def ml_materialize_rows(
    mut rows: List[TxnRow],
    reg: Registry,
    base_url: String,
    restrict_aliases: List[String],
) raises -> Int:
    """Apply the registry's ML rules to `rows` in place, via the on-device model
    (chat at `base_url`). For each ML rule, classify the descriptions of rows that
    don't already carry the tag — optionally restricted to `restrict_aliases` (the
    newly-extracted files at index time, so existing rows aren't re-classified
    every pass) — and add the tag where the model answers yes. Returns the number
    of rows changed; no-op when the registry has no ML rules. Raises if the engine
    chat is unreachable, so callers can treat the ML pass as best-effort."""
    var changed = 0
    var restrict = len(restrict_aliases) > 0
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if not r.is_ml():
            continue
        var idxs = List[Int]()
        var descs = List[String]()
        for t in range(len(rows)):
            if restrict and not _contains(restrict_aliases, rows[t].falias):
                continue
            if _contains(rows[t].tags, r.tag):
                continue  # already tagged (cached from a prior pass)
            idxs.append(t)
            descs.append(rows[t].desc.copy())
        if len(descs) == 0:
            continue
        var verdicts = classify_batch(base_url, r.ml_prompt, descs)
        for k in range(len(idxs)):
            if k < len(verdicts) and verdicts[k]:
                var row = rows[idxs[k]].copy()
                row.tags.append(r.tag.copy())
                rows[idxs[k]] = row^
                changed += 1
    return changed


def ml_materialize(base_url: String) raises -> Int:
    """Materialize ALL ML-rule tags over the stored transactions and persist —
    backs `millfolio materialize` (a lazy on-demand pass, since ML is slow and
    needs the engine up). Applies the deterministic tags first (preserving any
    existing ML tags), then the ML rules via the engine. Returns rows changed.
    """
    var reg = load_registry()
    var rows = load_txn_rows()
    var changed = retag(rows, reg)
    changed += ml_materialize_rows(rows, reg, base_url, List[String]())
    if changed > 0:
        write_txn_rows(rows)
    return changed


@fieldwise_init
struct TagInfo(Copyable, Movable):
    """One tag for the UI Tags panel: its name, the keywords that assign it (or
    the ML question), its scope description, and how many stored transactions
    currently carry it."""

    var name: String
    var keywords: List[String]
    var count: Int
    var description: String
    var ml_prompt: String


def tags_report() raises -> List[TagInfo]:
    """Per-tag (name, keywords, count, description, ml_prompt) over the effective
    registry + the stored transactions — what the Tags panel renders."""
    var reg = load_registry()
    var trows = load_txn_rows()
    var out = List[TagInfo]()
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        var n = 0
        for t in range(len(trows)):
            for g in range(len(trows[t].tags)):
                if trows[t].tags[g] == r.tag:
                    n += 1
                    break
        out.append(
            TagInfo(
                r.tag.copy(),
                r.keywords.copy(),
                n,
                r.description.copy(),
                r.ml_prompt.copy(),
            )
        )
    return out^


def _json_str(s: String) -> String:
    """`s` as a JSON string literal (quoted + escaped)."""
    var out = String('"')
    for cp in s.codepoints():
        var c = Int(cp)
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c < 32:
            out += " "
        else:
            out += chr(c)
    out += '"'
    return out^


def preview_categories(text: String) raises -> String:
    """Dry-run EDITED categories text against the stored transactions WITHOUT
    saving — the validation loop: how many transactions each rule would tag, plus
    a few example descriptions so the user can spot false positives (e.g. a credit
    `Crd Epay` digit-run wrongly matching `phone`) BEFORE committing. Deterministic
    rules are evaluated exactly; an ML rule can't be here (it needs the engine at
    index time) so it reports `ml:true` with no count. Parses `text` the same way
    the loader would treat an authoritative file. Returns
    `{"tags":[{"name","ml":bool,"count":N,"examples":[desc,…]}]}`."""
    var reg = Registry(parse_rules(text))
    var trows = load_txn_rows()
    var counts = List[Int]()
    var examples = List[List[String]]()
    for _i in range(len(reg.rules)):
        counts.append(0)
        examples.append(List[String]())
    for t in range(len(trows)):
        var tg = reg.tags_for(trows[t].desc)  # deterministic only
        for i in range(len(reg.rules)):
            if _contains(tg, reg.rules[i].tag):
                counts[i] += 1
                if len(examples[i]) < 5:
                    examples[i].append(trows[t].desc.copy())
    var out = String('{"tags":[')
    for i in range(len(reg.rules)):
        if i > 0:
            out += ","
        ref r = reg.rules[i]
        out += '{"name":' + _json_str(r.tag)
        out += ',"ml":' + ("true" if r.is_ml() else "false")
        out += ',"count":' + String(counts[i]) + ',"examples":['
        for e in range(len(examples[i])):
            if e > 0:
                out += ","
            out += _json_str(examples[i][e])
        out += "]}"
    out += "]}"
    return out^


def tags_report_json() raises -> String:
    """`{"tags":[{"name","keywords":[…],"count":N}]}` — the SAME payload the CLI
    `tags --json` prints and the app server's GET /api/tags returns."""
    var infos = tags_report()
    var out = String('{"tags":[')
    for i in range(len(infos)):
        if i > 0:
            out += ","
        ref ti = infos[i]
        out += '{"name":' + _json_str(ti.name) + ',"keywords":['
        for k in range(len(ti.keywords)):
            if k > 0:
                out += ","
            out += _json_str(ti.keywords[k])
        out += "],"
        out += '"description":' + _json_str(ti.description) + ","
        out += '"ml":' + _json_str(ti.ml_prompt) + ","
        out += '"count":' + String(ti.count) + "}"
    out += "]}"
    return out^


def transactions_json() raises -> String:
    """`{"transactions":[{"file","date","amount":N,"direction","desc","tags":[…]}]}`
    over the stored transactions in as-stored order — the payload the app server's
    GET /api/transactions returns so the Vault → Records view can surface the exact
    reconciled rows the app sums, each with its derived category tags. `amount` is a
    bare JSON number (non-negative magnitude); the sign is in `direction`
    (`"debit"` = money out, `"credit"` = money in)."""
    var rows = load_txn_rows()
    var out = String('{"transactions":[')
    for i in range(len(rows)):
        if i > 0:
            out += ","
        ref r = rows[i]
        out += '{"file":' + _json_str(r.falias)
        out += ',"date":' + _json_str(r.date)
        out += ',"amount":' + String(r.amount)
        out += ',"direction":' + _json_str(r.direction)
        out += ',"desc":' + _json_str(r.desc) + ',"tags":['
        for k in range(len(r.tags)):
            if k > 0:
                out += ","
            out += _json_str(r.tags[k])
        out += "]}"
    out += "]}"
    return out^
