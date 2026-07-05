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
from vault.derive.classify import (
    classify_batch,
    classify_batch_dedup,
    ML_BATCH,
)
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

# The tag-registry READ layer lives in `tags.mojo` (LanceDB- and network-free) so
# the privacy_box orchestrator can share it in-process without linking classify's
# HTTP client. The mutate paths below (retag/backfill/save) reuse it from here.
from vault.derive.tags import (
    config_dir,
    ensure_data_dir,
    txns_path,
    categories_path,
    ledger_path,
    load_txn_rows,
    load_ledger,
    load_registry,
    read_categories,
    effective_tags,
    effective_tag_descriptions,
    ml_ready_tags,
    codegen_tags_describe,
    contains,
    max_added_gen,
    write_categories,
)


# ── paths ─────────────────────────────────────────────────────────────────────


def _ledger_lock_dir() raises -> String:
    return config_dir() + "/ml_ledger.lock"


def controller_path() raises -> String:
    return config_dir() + "/backfiller.json"


# ── transactions side-table I/O ───────────────────────────────────────────────


def write_txn_rows(rows: List[TxnRow]) raises:
    ensure_data_dir()
    # Atomic replace: write a temp file then rename(2) over the target. The background
    # backfiller writes this file repeatedly; a concurrent reader (a query's
    # load_txn_rows, /api/transactions) must never observe a half-written file.
    var final = txns_path()
    var tmp = final + ".tmp"
    with open(tmp, "w") as f:
        f.write(txn_rows_to_tsv(rows))
    # libc rename(2) — atomic on the same filesystem. `String.unsafe_ptr()` is NOT
    # guaranteed NUL-terminated (the trailing byte is whatever the heap left there),
    # so passing it straight to a C string arg intermittently gave `rename(2)` a
    # garbage path → -1 → the tmp was never promoted and `transactions.tsv` never
    # appeared (0 transactions). `as_c_string_slice()` NUL-terminates in place (it
    # mutates, hence the owned `var` strings above) and is the correct C-string path.
    var rc = external_call["rename", Int32](
        tmp.as_c_string_slice(), final.as_c_string_slice()
    )
    if Int(rc) != 0:
        raise Error(
            "rename("
            + tmp
            + " -> "
            + final
            + ") failed (rc="
            + String(Int(rc))
            + ")"
        )


# ── registry (categories.txt is the source of truth) ──────────────────────────


def _reconcile_ledger() raises:
    """Drop ledger markers for any rule that is no longer an ACTIVE ML rule — so
    removing or de-ML'ing a category (via the editor) purges its backfill
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
    the backfill ledger (a removed/renamed ML rule loses its stale marker).
    Returns the number of transactions whose tags changed."""
    write_categories(categories_path(), text)
    var changed = effective_retag()
    _reconcile_ledger()
    return changed


# ── tags: names, backfill, report ──────────────────────────────────────


def _tags_equal(a: List[String], b: List[String]) -> Bool:
    """Order-sensitive tag-list equality (tags_for is deterministic in registry
    order, so a positional compare is enough)."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def retag(mut rows: List[TxnRow], reg: Registry) raises -> Int:
    """Re-apply the registry's DETERMINISTIC tags to every stored transaction in
    place (pure — no model call, no re-embed), PRESERVING any ML-rule tags already
    backfilled on the row. `tags_for` is deterministic-only (an ML rule never
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
        )  # deterministic keyword matches, registry order
        # Carry over any ML tag already on the row (it was a model call to compute,
        # cached here — re-backfilled only at index time for new transactions).
        for g in range(len(rows[i].tags)):
            ref t = rows[i].tags[g]
            if contains(ml, t) and not contains(new_tags, t):
                new_tags.append(t.copy())
        # Resolve `@tag` references over the FULL seed set (keyword matches ∪
        # carried-over ML tags) to a monotonic fixpoint — this is where group
        # categories (`essentials = @groceries, @utilities`) are materialised.
        reg.derive_ref_tags(rows[i].desc, new_tags)
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


def ml_backfill_rows(
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
            if restrict and not contains(restrict_aliases, rows[t].falias):
                continue
            if contains(rows[t].tags, r.tag):
                continue  # already tagged (cached from a prior pass)
            idxs.append(t)
            descs.append(rows[t].desc.copy())
        if len(descs) == 0:
            continue
        var dc = classify_batch_dedup(base_url, r.ml_prompt, descs)
        record_backfill_dedup(dc.seen, dc.unique, dc.unique_norm)
        for k in range(len(idxs)):
            if k < len(dc.verdicts) and dc.verdicts[k]:
                var row = rows[idxs[k]].copy()
                row.tags.append(r.tag.copy())
                rows[idxs[k]] = row^
                changed += 1
    return changed


# ── ML backfill ledger: durable state, lock, controller ────────────────
# The ledger (`ml_ledger.tsv`) is a per-rule completion marker keyed on the
# insertion generation (`TxnRow.added_gen`); see `vault.derive.ledger` +
# `QUERY_FLOW.md`. It is a CACHE — loss/corruption only costs re-work, never
# correctness — so writes are plain overwrites (a torn write self-heals via
# skip-malformed parsing) and the single-writer discipline is a best-effort
# mkdir-based advisory lock.


def save_ledger(markers: List[RuleMarker]) raises:
    ensure_data_dir()
    with open(ledger_path(), "w") as f:
        f.write(serialize_ledger(markers))


# A backfill slice is seconds long; a lock older than this is one a crashed/killed
# holder leaked (e.g. the app server killed mid-slice by a deploy), so it's safe to
# reclaim. This makes the lock self-healing — no manual `rmdir` after a crash.
comptime _LOCK_STALE_S = Int64(300)


def _lock_ts_path() raises -> String:
    return _ledger_lock_dir() + "/ts"


def _acquire_raw() -> Bool:
    """`mkdir` the lock (atomic) and stamp the acquire time. False if it exists.
    """
    try:
        mkdir(_ledger_lock_dir())
    except:
        return False
    try:  # best-effort staleness timestamp
        with open(_lock_ts_path(), "w") as f:
            f.write(String(_epoch_s()))
    except:
        pass
    return True


def _reclaim_if_stale() -> Bool:
    """Remove a LEAKED lock (timestamp older than `_LOCK_STALE_S`, or missing — a
    lock from before this stamping existed / a crash before the stamp). Returns True
    iff the lock was cleared (or already gone), so the caller can retry acquisition.
    Reclaiming only a stale lock keeps a LIVE holder's fresh lock intact."""
    try:
        var d = _ledger_lock_dir()
        if not exists(d):
            return True
        var stale = True  # no timestamp ⇒ a pre-stamp / crashed leak
        if exists(_lock_ts_path()):
            var raw: String
            with open(_lock_ts_path(), "r") as f:
                raw = f.read()
            stale = (
                _epoch_s() - Int64(atol(String(raw.strip())))
            ) > _LOCK_STALE_S
        if not stale:
            return False
        try:
            remove(_lock_ts_path())
        except:
            pass
        rmdir(d)
        return True
    except:
        return False


def try_lock() -> Bool:
    """Acquire the backfill lock (atomic POSIX `mkdir`). Returns False only if a
    LIVE writer holds it — the app-server worker then skips its tick, so a question
    is never delayed. A lock leaked by a crashed/killed holder is auto-reclaimed
    once stale (see `_LOCK_STALE_S`), so backfill self-heals instead of wedging.
    """
    if _acquire_raw():
        return True
    if _reclaim_if_stale() and _acquire_raw():
        return True
    return False


def unlock():
    # Remove the timestamp file first: rmdir fails on a non-empty dir, so skipping
    # this would leave the lock permanently held.
    try:
        remove(_lock_ts_path())
    except:
        pass
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
    """Pause backfill for `seconds` from now; the workers no-op until it
    elapses, then auto-resume. `seconds <= 0` resumes immediately."""
    if seconds <= 0:
        _write_controller(Int64(0))
    else:
        _write_controller(_epoch_s() + Int64(seconds))


def is_paused() raises -> Bool:
    return _read_paused_until() > _epoch_s()


def priority_path() raises -> String:
    return config_dir() + "/backfiller_priority"


def get_priority() raises -> String:
    """The backfill THROTTLE — "high" | "medium" | "low" (default "medium").
    Governs how long the background worker naps BETWEEN classify slices: low leaves
    the GPU mostly free (long idle gaps → laptop stays usable), high runs nearly
    back-to-back (fastest, GPU-heavy)."""
    var p = priority_path()
    if exists(p):
        var t: String
        with open(p, "r") as f:
            t = f.read()
        var v = String(t.strip())
        if v == "high" or v == "low" or v == "medium":
            return v^
    return String("medium")


def set_priority(p: String) raises:
    var v = String(p.strip())
    if v != "high" and v != "low":
        v = String("medium")
    ensure_data_dir()
    with open(priority_path(), "w") as f:
        f.write(v)


def nap_ms_for_priority(p: String) -> Int:
    """Nap (ms) between active classify slices for a priority — the GPU throttle.
    """
    if p == "high":
        return 100
    if p == "low":
        return 5000
    return 1200  # medium


# ── backfill dedup savings counter (surfaced on the Stats page) ────────
# Cumulative across passes: rows_seen = transactions handed to classification,
# rows_classified = DISTINCT descriptions actually sent to the model (recurring charges
# collapse). saved = rows_seen - rows_classified. Best-effort JSON in the data dir.


def _dedup_stats_path() raises -> String:
    return config_dir() + "/backfill_dedup.json"


def _json_int(text: String, key: String) -> Int:
    """Integer value of `"key":<int>` in a tiny JSON blob (0 if absent/malformed).
    """
    var k = String('"') + key + '":'
    var at = text.find(k)
    if at < 0:
        return 0
    var i = at + k.byte_length()
    var b = text.as_bytes()
    while i < len(b) and (Int(b[i]) == 32 or Int(b[i]) == 9):
        i += 1
    var neg = i < len(b) and Int(b[i]) == 45  # '-'
    if neg:
        i += 1
    var v = 0
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        v = v * 10 + (Int(b[i]) - 48)
        i += 1
    return -v if neg else v


def record_backfill_dedup(seen: Int, unique: Int, unique_norm: Int) raises:
    """Accumulate one classify slice's counts into the cumulative counter: rows handed
    in, DISTINCT descriptions actually classified (exact dedup), and the PROJECTED
    distinct-after-normalization count (`unique_norm` — a measurement, not what's
    classified). Best-effort — a stats write must never fail a backfill."""
    try:
        var seen_tot = seen
        var uniq_tot = unique
        var norm_tot = unique_norm
        if exists(_dedup_stats_path()):
            var text: String
            with open(_dedup_stats_path(), "r") as f:
                text = f.read()
            seen_tot += _json_int(text, "rows_seen")
            uniq_tot += _json_int(text, "rows_classified")
            norm_tot += _json_int(text, "rows_norm")
        ensure_data_dir()
        with open(_dedup_stats_path(), "w") as f:
            f.write(
                String('{"rows_seen":')
                + String(seen_tot)
                + ',"rows_classified":'
                + String(uniq_tot)
                + ',"rows_norm":'
                + String(norm_tot)
                + "}\n"
            )
    except:
        pass


def backfill_dedup_json() raises -> String:
    """The cumulative dedup counter for /api/stats. `saved` = exact-dedup savings
    (rows_seen - rows_classified); `saved_norm` = the EXTRA that normalization would
    save on top (rows_classified - rows_norm), a projection:
    `{"rows_seen":N,"rows_classified":M,"rows_norm":K,"saved":N-M,"saved_norm":M-K}`.
    """
    var seen = 0
    var uniq = 0
    var norm = 0
    if exists(_dedup_stats_path()):
        var text: String
        with open(_dedup_stats_path(), "r") as f:
            text = f.read()
        seen = _json_int(text, "rows_seen")
        uniq = _json_int(text, "rows_classified")
        norm = _json_int(text, "rows_norm")
    return (
        String('{"rows_seen":')
        + String(seen)
        + ',"rows_classified":'
        + String(uniq)
        + ',"rows_norm":'
        + String(norm)
        + ',"saved":'
        + String(seen - uniq)
        + ',"saved_norm":'
        + String(uniq - norm)
        + "}"
    )


# ── ML backfill: the ledger-based, incremental, resumable drain ────────


def _contains_int(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


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
    var max_gen = max_added_gen(rows)
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
                if rows[t].added_gen == g and not contains(rows[t].tags, r.tag):
                    idxs.append(t)
                    descs.append(rows[t].desc.copy())
            if len(descs) > 0:
                # The slow part — no lock is meant to span it (the CLI holds the
                # lock for the whole drain; the worker's slice is bounded).
                var dc = classify_batch_dedup(base_url, r.ml_prompt, descs)
                record_backfill_dedup(dc.seen, dc.unique, dc.unique_norm)
                for k in range(len(idxs)):
                    if k < len(dc.verdicts) and dc.verdicts[k]:
                        var row = rows[idxs[k]].copy()
                        row.tags.append(r.tag.copy())
                        rows[idxs[k]] = row^
                        changed += 1
                groups_used += 1
            # Everything with added_gen <= g is now backfilled for this rule.
            upsert_marker(markers, r.tag, cur, g)
    if changed > 0:
        write_txn_rows(rows)
    save_ledger(markers)
    return changed


def ml_backfill(base_url: String) raises -> Int:
    """Drain the WHOLE ML-backfill queue and persist — backs `millfolio
    backfill`. Ledger-based: each true negative is classified once (the marker
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


def ml_backfill_slice(base_url: String) raises -> Int:
    """One bounded generation-batch of backfill — the app-server's
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


def ledger_note_backfilled(
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


# ── readiness gate + backfill status (for codegen + the UI panel) ──────


def backfill_status_json() raises -> String:
    """`{status, paused_until, perTag:[{tag,question,total,evaluated,pending,yes,
    ready}], pendingTotal}` — the lock-free read backing GET /api/backfill/status
    and the Tags-tab Backfill panel. `evaluated`/`pending` are derived from
    the ledger watermark vs each row's `added_gen`; `yes` is the live `.tags`
    count."""
    var reg = load_registry()
    var rows = load_txn_rows()
    var markers = load_ledger()
    var max_gen = max_added_gen(rows)
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
    out += String(paused_until)
    out += ',"priority":"' + get_priority() + '","perTag":['
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
            if contains(rows[t].tags, r.tag):
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
    anything — no `.tags`, no ledger, no backfill. Classifies stored
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
    an AI rule matches 0 here — it backfills via the worker / `backfill`).
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


# ── amount-reveal password ────────────────────────────────────────────────────
# A local privacy screen: on-screen amounts (and totals) stay masked until the
# owner enters a passphrase. The server holds the secret and only releases amounts
# on a match, so it's genuinely server-enforced. Plaintext in the data dir is the
# right trade here — anyone with local file access already has the transactions, and
# storing it in the clear is what lets `mill get amount-password` look it up. NOT a
# hard boundary against a determined local attacker; it's a shoulder-surf screen.


def amount_password_path() raises -> String:
    return config_dir() + "/amount_password"


def _pw_wordlist() -> List[String]:
    """A small curated list of short, unambiguous words (no homophones / look-alikes)
    for memorable 3-word passphrases. 128 words → 3 picks ≈ 21 bits — ample for a
    local screen."""
    return [
        String("amber"),
        "anchor",
        "apple",
        "arrow",
        "autumn",
        "bacon",
        "badge",
        "bamboo",
        "banjo",
        "basil",
        "beacon",
        "bison",
        "blossom",
        "bramble",
        "branch",
        "bronze",
        "bubble",
        "cabin",
        "cactus",
        "canyon",
        "cedar",
        "cherry",
        "clover",
        "cobalt",
        "comet",
        "copper",
        "coral",
        "cotton",
        "cricket",
        "crimson",
        "crystal",
        "dahlia",
        "daisy",
        "dolphin",
        "domino",
        "dragon",
        "ember",
        "emerald",
        "falcon",
        "feather",
        "fennel",
        "ferry",
        "fjord",
        "flint",
        "forest",
        "fossil",
        "garnet",
        "ginger",
        "glacier",
        "granite",
        "harbor",
        "hazel",
        "helmet",
        "hollow",
        "indigo",
        "island",
        "ivory",
        "jasmine",
        "jersey",
        "jungle",
        "kettle",
        "lagoon",
        "lantern",
        "lemon",
        "lilac",
        "linen",
        "lotus",
        "lumber",
        "magnet",
        "maple",
        "marble",
        "meadow",
        "mellow",
        "mint",
        "monsoon",
        "mulberry",
        "nectar",
        "nickel",
        "nutmeg",
        "oasis",
        "olive",
        "orchid",
        "otter",
        "oxide",
        "paddle",
        "pastel",
        "pebble",
        "pepper",
        "pewter",
        "pigeon",
        "pillow",
        "pine",
        "pistol",
        "pixel",
        "plaza",
        "pocket",
        "pollen",
        "poppy",
        "prairie",
        "pretzel",
        "pumpkin",
        "quartz",
        "quiver",
        "raccoon",
        "radish",
        "ribbon",
        "river",
        "rocket",
        "rustic",
        "saffron",
        "salmon",
        "sapling",
        "sequoia",
        "shadow",
        "silver",
        "sparrow",
        "spruce",
        "sunset",
        "thistle",
        "timber",
        "tulip",
        "velvet",
        "walnut",
        "willow",
        "yarrow",
        "zephyr",
    ]


def _rand_below(n: Int) -> Int:
    """A uniform random index in [0, n) via libc `arc4random_uniform` (no modulo
    bias, no /dev/urandom bookkeeping)."""
    return Int(external_call["arc4random_uniform", UInt32](UInt32(n)))


def _gen_amount_password() -> String:
    var words = _pw_wordlist()
    var out = String("")
    for i in range(3):
        if i > 0:
            out += "-"
        out += words[_rand_below(len(words))]
    return out^


def _norm_pw(s: String) -> String:
    """Normalize for comparison: lowercase, spaces → hyphens, trimmed — so
    "River Copper Lantern" and "river-copper-lantern" match."""
    var t = String(s.strip())
    var out = String("")
    var p = t.unsafe_ptr()
    for i in range(t.byte_length()):
        var c = Int(p[i])
        if c == 32:  # space → hyphen
            out += "-"
        elif c >= 65 and c <= 90:  # A-Z → a-z
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def get_amount_password() raises -> String:
    """The reveal passphrase. Generates + persists a random 3-word one on first use,
    so there is always something to enter (and to look up via `mill get`)."""
    ensure_data_dir()
    var p = amount_password_path()
    if exists(p):
        var text: String
        with open(p, "r") as f:
            text = f.read()
        var pw = String(text.strip())
        if pw.byte_length() > 0:
            return pw^
    var fresh = _gen_amount_password()
    with open(p, "w") as f:
        f.write(fresh)
    return fresh^


def set_amount_password(words: String) raises:
    """Overwrite the reveal passphrase with the user's own (trimmed as stored; the
    verifier normalizes case/spacing on comparison)."""
    ensure_data_dir()
    with open(amount_password_path(), "w") as f:
        f.write(String(words.strip()))


def verify_amount_password(candidate: String) raises -> Bool:
    """True iff `candidate` matches the stored passphrase (case/spacing-insensitive).
    An empty candidate never matches."""
    if String(candidate.strip()).byte_length() == 0:
        return False
    return _norm_pw(candidate) == _norm_pw(get_amount_password())


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
            if contains(tg, reg.rules[i].tag):
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
    "merchant","country","state","tags":[…]}]}` over the stored transactions in
    as-stored order — the payload the
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
        out += ',"desc":' + _json_str(r.desc)
        # Deterministic location split computed at index time (parse_location):
        # merchant = cleaned brand, country = ISO3, state = US 2-letter. Sparse —
        # only card-style descriptors carry them (transfers/checking rows are "").
        out += ',"merchant":' + _json_str(r.merchant)
        out += ',"country":' + _json_str(r.country)
        out += ',"state":' + _json_str(r.state)
        out += ',"tags":['
        for k in range(len(r.tags)):
            if k > 0:
                out += ","
            out += _json_str(r.tags[k])
        out += "]}"
    out += "]}"
    return out^
