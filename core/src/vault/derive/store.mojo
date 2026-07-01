"""Store — the on-device derived-attribute store + registry I/O.

The on-device DATA-dir files that back categorization (see `config_dir` —
`~/Library/Application Support/Millfolio/data`, overridable via
`MILLFOLIO_DATA_DIR`): `categories.txt` (the tag registry — SOURCE OF TRUTH,
seeded with the built-in defaults, see `vault.derive.categorize`) and the `.tags`
column of `transactions.tsv`.

This module is deliberately **LanceDB-free** (it touches only those two files +
pure helpers), so BOTH the `millfolio` CLI and the app server import it and call
the SAME functions in-process — no spawning a separate engine binary for tags /
retag / category edits. The heavy index/embedding work stays in `vault.index`.
"""

from std.os import getenv, mkdir, rmdir, remove, makedirs
from std.os.path import exists
from std.ffi import external_call
from std.time import perf_counter_ns

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
from vault.derive.classify import classify_batch, ML_BATCH
from vault.derive.ledger import (
    RuleMarker,
    qhash,
    is_pending,
    is_ready,
    count_pending,
    parse_ledger,
    serialize_ledger,
    find_marker,
    marker_done_gen,
    upsert_marker,
    drop_marker,
    GEN_ABSENT,
)


# ── paths ─────────────────────────────────────────────────────────────────────


def config_dir() raises -> String:
    """The on-device DATA dir — the index, extracted transactions, category rules,
    materialization ledger, and usage/history stores. macOS-native home (matches the
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


def _ledger_lock_dir() raises -> String:
    return config_dir() + "/ml_ledger.lock"


def controller_path() raises -> String:
    return config_dir() + "/materializer.json"


# ── transactions side-table I/O ───────────────────────────────────────────────


def load_txn_rows() raises -> List[TxnRow]:
    if not exists(txns_path()):
        return List[TxnRow]()
    var text: String
    with open(txns_path(), "r") as f:
        text = f.read()
    return tsv_to_txn_rows(text)


def write_txn_rows(rows: List[TxnRow]) raises:
    ensure_data_dir()
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
        ensure_data_dir()
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


def _reconcile_ledger() raises:
    """Drop ledger markers for any rule that is no longer an ACTIVE ML rule — so
    removing or de-ML'ing a category (via the editor) purges its materialization
    marker automatically (the cancel path). Its `.tags` are stripped by the retag
    pass, since `retag` only carries over tags of rules still in the registry.
    """
    var reg = load_registry()
    var markers = load_ledger()
    if len(markers) == 0:
        return
    var kept = List[RuleMarker]()
    for i in range(len(markers)):
        var keep = False
        for j in range(len(reg.rules)):
            if reg.rules[j].is_ml() and reg.rules[j].tag == markers[i].rule:
                keep = True
                break
        if keep:
            kept.append(markers[i].copy())
    if len(kept) != len(markers):
        save_ledger(kept)


def save_categories(text: String) raises -> Int:
    """Overwrite `categories.txt` with the editor's content (this makes the file
    'touched' → authoritative) and re-tag the stored transactions. Also reconciles
    the materialization ledger (a removed/renamed ML rule loses its stale marker).
    Returns the number of transactions whose tags changed."""
    _write_categories(categories_path(), text)
    var changed = effective_retag()
    _reconcile_ledger()
    return changed


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


# ── ML materialization ledger: durable state, lock, controller ────────────────
# The ledger (`ml_ledger.tsv`) is a per-rule completion marker keyed on the
# insertion generation (`TxnRow.added_gen`); see `vault.derive.ledger` +
# `QUERY_FLOW.md`. It is a CACHE — loss/corruption only costs re-work, never
# correctness — so writes are plain overwrites (a torn write self-heals via
# skip-malformed parsing) and the single-writer discipline is a best-effort
# mkdir-based advisory lock.


def load_ledger() raises -> List[RuleMarker]:
    if not exists(ledger_path()):
        return List[RuleMarker]()
    var text: String
    with open(ledger_path(), "r") as f:
        text = f.read()
    return parse_ledger(text)


def save_ledger(markers: List[RuleMarker]) raises:
    ensure_data_dir()
    with open(ledger_path(), "w") as f:
        f.write(serialize_ledger(markers))


def try_lock() -> Bool:
    """Acquire the materialization lock (atomic POSIX `mkdir`). Returns False if
    another writer holds it — the app-server worker skips its tick, so a question
    is never delayed. Best-effort: a lock leaked by a crashed process must be
    cleared by hand (`rmdir ~/.config/millfolio/ml_ledger.lock`)."""
    try:
        mkdir(_ledger_lock_dir())
        return True
    except:
        return False


def unlock():
    try:
        rmdir(_ledger_lock_dir())
    except:
        pass


def _epoch_s() -> Int64:
    """Unix epoch seconds (time(2) with a NULL arg) — for the pause deadline."""
    var null = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(0)
    )
    return external_call["time", Int64](null)


def _read_paused_until() raises -> Int64:
    """The `paused_until` epoch from the controller file (0 = not paused). The
    file is tiny JSON; we scan for the numeric field rather than parse fully."""
    if not exists(controller_path()):
        return Int64(0)
    var text: String
    with open(controller_path(), "r") as f:
        text = f.read()
    var key = String('"paused_until":')
    var at = text.find(key)
    if at < 0:
        return Int64(0)
    var i = at + key.byte_length()
    var b = text.as_bytes()
    while i < len(b) and (Int(b[i]) == 32 or Int(b[i]) == 9):
        i += 1
    var v = Int64(0)
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        v = v * 10 + Int64(Int(b[i]) - 48)
        i += 1
    return v


def _write_controller(paused_until: Int64) raises:
    ensure_data_dir()
    var status = String("paused") if paused_until > _epoch_s() else String(
        "idle"
    )
    var out = String('{"status":"') + status + '","paused_until":'
    out += String(paused_until) + "}\n"
    with open(controller_path(), "w") as f:
        f.write(out)


def set_pause(seconds: Int) raises:
    """Pause materialization for `seconds` from now; the workers no-op until it
    elapses, then auto-resume. `seconds <= 0` resumes immediately."""
    if seconds <= 0:
        _write_controller(Int64(0))
    else:
        _write_controller(_epoch_s() + Int64(seconds))


def is_paused() raises -> Bool:
    return _read_paused_until() > _epoch_s()


# ── ML materialization: the ledger-based, incremental, resumable drain ────────


def _contains_int(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _max_added_gen(rows: List[TxnRow]) -> Int:
    var m = GEN_ABSENT
    for i in range(len(rows)):
        if rows[i].added_gen > m:
            m = rows[i].added_gen
    return m


def _pending_gens(rows: List[TxnRow], mdg: Int) -> List[Int]:
    """The distinct insertion generations still to classify for a rule at marker
    watermark `mdg` (rows with `added_gen > mdg`), ascending — so the drain
    advances the watermark one whole generation at a time (a watermark can't
    express a partially-done generation)."""
    var gens = List[Int]()
    for t in range(len(rows)):
        var g = rows[t].added_gen
        if g > mdg and not _contains_int(gens, g):
            gens.append(g)
    # Selection sort ascending — the number of distinct generations (≈ index runs)
    # is tiny.
    for a in range(len(gens)):
        var mi = a
        for b in range(a + 1, len(gens)):
            if gens[b] < gens[mi]:
                mi = b
        if mi != a:
            var tmp = gens[a]
            gens[a] = gens[mi]
            gens[mi] = tmp
    return gens^


def _ml_drain_locked(base_url: String, max_gen_groups: Int) raises -> Int:
    """The core drain (caller holds the lock). Applies the deterministic tags
    first (preserving cached ML tags), then for each ML rule classifies the
    PENDING generations (`added_gen > done_gen`) in ascending order, adds the tag
    where the model says yes, and advances the rule's marker one generation at a
    time. `max_gen_groups > 0` bounds how many generation-batches run this call
    (the between-questions worker passes 1); 0 drains everything (the CLI). Rows
    that already carry the tag are skipped (their positives are cached), so a
    re-pass only re-does what a generation genuinely needs. Returns rows changed.
    """
    var reg = load_registry()
    var rows = load_txn_rows()
    var markers = load_ledger()
    var changed = retag(
        rows, reg
    )  # deterministic tags stay fresh; ML preserved
    var max_gen = _max_added_gen(rows)
    var groups_used = 0
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if not r.is_ml():
            continue
        var cur = qhash(r.ml_prompt)
        var mdg = marker_done_gen(markers, r.tag, cur)
        var gens = _pending_gens(rows, mdg)
        if len(gens) == 0:
            # Nothing pending. Record the marker if it's stale/absent (e.g. an
            # edited question over an already-empty pending set, or a fresh rule
            # on an empty vault) so the readiness gate reflects reality.
            if mdg == GEN_ABSENT:
                upsert_marker(markers, r.tag, cur, max_gen)
            continue
        for gi in range(len(gens)):
            if max_gen_groups > 0 and groups_used >= max_gen_groups:
                break
            var g = gens[gi]
            var idxs = List[Int]()
            var descs = List[String]()
            for t in range(len(rows)):
                if rows[t].added_gen == g and not _contains(
                    rows[t].tags, r.tag
                ):
                    idxs.append(t)
                    descs.append(rows[t].desc.copy())
            if len(descs) > 0:
                # The slow part — no lock is meant to span it (the CLI holds the
                # lock for the whole drain; the worker's slice is bounded).
                var verdicts = classify_batch(base_url, r.ml_prompt, descs)
                for k in range(len(idxs)):
                    if k < len(verdicts) and verdicts[k]:
                        var row = rows[idxs[k]].copy()
                        row.tags.append(r.tag.copy())
                        rows[idxs[k]] = row^
                        changed += 1
                groups_used += 1
            # Everything with added_gen <= g is now materialized for this rule.
            upsert_marker(markers, r.tag, cur, g)
    if changed > 0:
        write_txn_rows(rows)
    save_ledger(markers)
    return changed


def ml_materialize(base_url: String) raises -> Int:
    """Drain the WHOLE ML-materialization queue and persist — backs `millfolio
    materialize`. Ledger-based: each true negative is classified once (the marker
    remembers it), so re-runs after adding a statement or a new rule only do the
    genuinely-new work. No-op (returns 0) if another writer holds the lock.
    """
    if not try_lock():
        return 0
    try:
        var changed = _ml_drain_locked(base_url, 0)
        unlock()
        return changed
    except e:
        unlock()
        raise e^


def ml_materialize_slice(base_url: String) raises -> Int:
    """One bounded generation-batch of materialization — the app-server's
    between-questions worker. Non-blocking try-lock (skip if the CLI holds it) and
    honors the pause deadline, so it can never delay a question. Returns rows
    changed (0 when paused, locked, or nothing pending)."""
    if is_paused():
        return 0
    if not try_lock():
        return 0
    try:
        var changed = _ml_drain_locked(base_url, 1)
        unlock()
        return changed
    except e:
        unlock()
        raise e^


def ledger_note_materialized(
    reg: Registry, rows: List[TxnRow], cur_gen: Int
) raises:
    """Called at index time AFTER the inline ML pass has classified the freshly
    inserted generation (`cur_gen`) for every active ML rule. Advances each rule's
    marker to `cur_gen` — but ONLY when the rule has no OLDER pending generation
    (nothing below `cur_gen` left uncovered); otherwise the backlog (a newly-added
    rule, or the first post-upgrade pass) is left for the drain. This is what keeps
    a routine `mill index` from re-classifying the same negatives the drain would
    otherwise redo every pass. Best-effort — skip silently if the ledger can't be
    written."""
    try:
        var markers = load_ledger()
        for i in range(len(reg.rules)):
            ref r = reg.rules[i]
            if not r.is_ml():
                continue
            var cur = qhash(r.ml_prompt)
            var mdg = marker_done_gen(markers, r.tag, cur)
            var older_pending = False
            for t in range(len(rows)):
                var g = rows[t].added_gen
                if g > mdg and g < cur_gen:
                    older_pending = True
                    break
            if not older_pending:
                upsert_marker(markers, r.tag, cur, cur_gen)
        save_ledger(markers)
    except:
        pass


# ── readiness gate + materialization status (for codegen + the UI panel) ──────


def ml_ready_tags() raises -> List[String]:
    """The ML-rule tag names that are fully materialized at their current question
    hash — safe for codegen to advertise as an exact `.tags` filter. A pending /
    stale rule is withheld (see `codegen_tags_describe`) so a `"gym" in t.tags`
    filter can never return a false empty over un-classified rows."""
    var reg = load_registry()
    var rows = load_txn_rows()
    var markers = load_ledger()
    var max_gen = _max_added_gen(rows)
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
    materialized. Withholding a pending ML tag makes codegen classify inline (or
    skip it) rather than filter an empty `.tags` and report a false "no X". Backs
    `millfolio tags --describe`."""
    var reg = load_registry()
    var ready = ml_ready_tags()
    var out = String("")
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if r.is_ml() and not _contains(ready, r.tag):
            continue  # pending / stale ML rule → withhold from the fast filter
        out += r.tag + "\t" + r.description + "\n"
    return out^


def materialize_status_json() raises -> String:
    """`{status, paused_until, perTag:[{tag,question,total,evaluated,pending,yes,
    ready}], pendingTotal}` — the lock-free read backing GET /api/materialize/status
    and the Tags-tab Materialization panel. `evaluated`/`pending` are derived from
    the ledger watermark vs each row's `added_gen`; `yes` is the live `.tags`
    count."""
    var reg = load_registry()
    var rows = load_txn_rows()
    var markers = load_ledger()
    var max_gen = _max_added_gen(rows)
    var total = len(rows)
    var paused_until = _read_paused_until()
    var status = String("paused") if paused_until > _epoch_s() else String(
        "idle"
    )

    # Per-rule insertion gens, once, for the pending counts.
    var gens = List[Int]()
    for t in range(len(rows)):
        gens.append(rows[t].added_gen)

    var pending_total = 0
    var out = String('{"status":"') + status + '","paused_until":'
    out += String(paused_until) + ',"perTag":['
    var first = True
    for i in range(len(reg.rules)):
        ref r = reg.rules[i]
        if not r.is_ml():
            continue
        var cur = qhash(r.ml_prompt)
        var mdg = marker_done_gen(markers, r.tag, cur)
        var pending = count_pending(gens, cur, mdg, cur)
        var evaluated = total - pending
        var ready = is_ready(cur, mdg, cur, max_gen)
        var yes = 0
        for t in range(len(rows)):
            if _contains(rows[t].tags, r.tag):
                yes += 1
        pending_total += pending
        if not first:
            out += ","
        first = False
        out += '{"tag":' + _json_str(r.tag)
        out += ',"question":' + _json_str(r.ml_prompt)
        out += ',"total":' + String(total)
        out += ',"evaluated":' + String(evaluated)
        out += ',"pending":' + String(pending)
        out += ',"yes":' + String(yes)
        out += ',"ready":' + ("true" if ready else "false") + "}"
    out += '],"pendingTotal":' + String(pending_total) + "}"
    return out^


# ── search / define: AI-rule preview + add a category (the unified search bar) ─


def preview_ml_json(base_url: String, prompt: String) raises -> String:
    """Time-boxed (~5s) preview of an AI rule (`tag : prompt`) WITHOUT persisting
    anything — no `.tags`, no ledger, no materialization. Classifies stored
    transactions with `prompt` (in insertion order) until the budget elapses, then
    reports how many of the SAMPLE matched. The caller projects a total from
    `matched / evaluated`. This is the "evaluate for 5 seconds, show the count"
    step before the user commits to creating the tag. Returns
    `{"matched":M,"evaluated":E,"total":T}`."""
    var rows = load_txn_rows()
    var total = len(rows)
    comptime BUDGET_NS = 5_000_000_000  # ~5 seconds
    comptime EX_CAP = 4  # example descriptions to surface for each verdict
    var start = perf_counter_ns()
    var evaluated = 0
    var matched = 0
    var yes_ex = List[String]()  # a few descriptions the model tagged yes
    var no_ex = List[String]()  # …and a few it tagged no — the sanity check
    var i = 0
    while i < total:
        if perf_counter_ns() - start >= BUDGET_NS:
            break
        var end = i + ML_BATCH
        if end > total:
            end = total
        var descs = List[String]()
        for k in range(i, end):
            descs.append(rows[k].desc.copy())
        var verdicts = classify_batch(base_url, prompt, descs)
        for k in range(len(verdicts)):
            evaluated += 1
            if verdicts[k]:
                matched += 1
                if len(yes_ex) < EX_CAP:
                    yes_ex.append(rows[i + k].desc.copy())
            elif len(no_ex) < EX_CAP:
                no_ex.append(rows[i + k].desc.copy())
        i = end
    return (
        '{"matched":'
        + String(matched)
        + ',"evaluated":'
        + String(evaluated)
        + ',"total":'
        + String(total)
        + ',"matchedExamples":'
        + _json_str_list(yes_ex)
        + ',"unmatchedExamples":'
        + _json_str_list(no_ex)
        + "}"
    )


def _sanitize_tag(s: String) -> String:
    """A tag name can't hold the registry separators (`,` `=` `:` parens) or a
    tab/newline; strip them and trim (mirrors the editor's own cleaning)."""
    var out = String("")
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var c = Int(p[i])
        # , = : ( ) tab newline cr
        if (
            c == 44
            or c == 61
            or c == 58
            or c == 40
            or c == 41
            or c == 9
            or c == 10
            or c == 13
        ):
            continue
        out += chr(c)
    return String(out.strip())


def add_category(name: String, keywords: String, prompt: String) raises -> Int:
    """Append a new category rule to `categories.txt` and re-tag — the "Create tag"
    action of the search/define bar. A non-empty `prompt` makes an AI rule
    (`name : prompt`); otherwise a keyword rule (`name = keywords`). Returns the
    number of transactions re-tagged (0 if the name is empty or nothing matched;
    an AI rule matches 0 here — it materializes via the worker / `materialize`).
    Reuses `save_categories`, so the ledger is reconciled too."""
    var clean = _sanitize_tag(name)
    if clean.byte_length() == 0:
        return 0
    var text = read_categories()
    if text.byte_length() > 0 and not text.endswith("\n"):
        text += "\n"
    var q = String(prompt.strip())
    if q.byte_length() > 0:
        text += clean + " : " + q + "\n"
    else:
        var kw = String(keywords.strip())
        if kw.byte_length() == 0:
            return 0
        text += clean + " = " + kw + "\n"
    return save_categories(text)


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


def _json_str_list(xs: List[String]) -> String:
    """A List[String] as a JSON array of string literals."""
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += ","
        out += _json_str(xs[i])
    out += "]"
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
    var examples = List[List[String]]()  # a few descriptions each rule DOES tag
    var non_examples = List[
        List[String]
    ]()  # …and a few it does NOT — the sanity check
    for _i in range(len(reg.rules)):
        counts.append(0)
        examples.append(List[String]())
        non_examples.append(List[String]())
    for t in range(len(trows)):
        var tg = reg.tags_for(trows[t].desc)  # deterministic only
        for i in range(len(reg.rules)):
            if _contains(tg, reg.rules[i].tag):
                counts[i] += 1
                if len(examples[i]) < 5:
                    examples[i].append(trows[t].desc.copy())
            elif len(non_examples[i]) < 5:
                non_examples[i].append(trows[t].desc.copy())
    var out = String('{"tags":[')
    for i in range(len(reg.rules)):
        if i > 0:
            out += ","
        ref r = reg.rules[i]
        out += '{"name":' + _json_str(r.tag)
        out += ',"ml":' + ("true" if r.is_ml() else "false")
        out += ',"count":' + String(counts[i])
        out += ',"examples":' + _json_str_list(examples[i])
        out += ',"nonExamples":' + _json_str_list(non_examples[i]) + "}"
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


def transactions_json(include_amounts: Bool = True) raises -> String:
    """`{"transactions":[{"file","date","year","amount":N|null,"direction","desc",
    "tags":[…]}]}` over the stored transactions in as-stored order — the payload the
    app server's GET /api/transactions returns for the Vault → Records view. `amount`
    is a bare JSON number (non-negative magnitude); the sign is in `direction`
    (`"debit"` = money out, `"credit"` = money in).

    When `include_amounts` is False (the DEFAULT the server uses until the user
    passes the Touch-ID gate), `amount` is emitted as `null` — so the actual figures
    never reach the browser until unlocked (the privacy screen). `direction` is kept
    so the UI can still show a +/- mask."""
    var rows = load_txn_rows()
    var out = String('{"transactions":[')
    for i in range(len(rows)):
        if i > 0:
            out += ","
        ref r = rows[i]
        out += '{"file":' + _json_str(r.falias)
        out += ',"date":' + _json_str(r.date)
        out += ',"year":' + String(r.year)
        if include_amounts:
            out += ',"amount":' + String(r.amount)
        else:
            out += ',"amount":null'
        out += ',"direction":' + _json_str(r.direction)
        out += ',"desc":' + _json_str(r.desc) + ',"tags":['
        for k in range(len(r.tags)):
            if k > 0:
                out += ","
            out += _json_str(r.tags[k])
        out += "]}"
    out += "]}"
    return out^
