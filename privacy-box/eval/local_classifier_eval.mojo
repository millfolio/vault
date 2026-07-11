"""local_classifier_eval — quantify the on-device yes/no classifier, ML + operational.

The blog claims the local model answers targeted yes/no questions about a
transaction well. This program measures that ON YOUR OWN VAULT without leaking
anything: it uses a deterministic KEYWORD tag as the reference label (default:
`phone` — a curated merchant list), asks the local model the equivalent yes/no
question over the same records, and prints ONLY aggregates — counts, rates,
percentages, timings. No description, merchant, amount, or date appears in the
output, so the summary is safe to publish.

    mill run vault/privacy-box/eval/local_classifier_eval.mojo

Knobs (edit below): TRUTH_TAG — any KEYWORD tag from your categories.txt;
QUESTION — the yes/no question that should mean the same thing. Caveat printed
with the results: the keyword tag is imperfect truth, so disagreement counts
are "model vs rule", not certified model errors.

Like the real tag backfill, distinct descriptions are classified ONCE and the
verdict fans out to every row sharing the description — the dedup factor it
reports is the same saving the backfiller gets. A stride sample caps the model
work so a huge vault still finishes in minutes.
"""

from vault import *
from std.time import perf_counter_ns

# Loopback-only (the sandbox allows 127.0.0.1): ask the ENGINE which chat model
# is actually serving — provenance for the numbers, and the fastest way to spot
# "wrong model selected" when the answer mix comes back broken.
from flare.http import HttpClient, Request

comptime TRUTH_TAG = "groceries"
# Phrased to COOPERATE with the ask_local_batch wrapper (which tells the model
# "use 'none' when it does not apply"): an answer-only-yes-or-no question made
# the model flood 'none'/free-text (0 yes AND 0 no in a real run). Spell out
# both branches and forbid the escape hatch.
comptime QUESTION = (
    "For each snippet: answer 'yes' if it is a grocery store or supermarket"
    " purchase (food shopping), answer 'no' for everything else (dining out,"
    " restaurants, coffee shops, and any non-grocery charge). Every answer"
    " must be exactly 'yes' or 'no' — never 'none', never anything else."
)
comptime MAX_DISTINCT = 400  # cap on model work; stride-sampled above this
comptime TIME_BUDGET_S = 300  # stop classifying after ~this long (0 = no cap);
# metrics are computed over whatever was classified.
comptime CHUNK = 10  # distinct descriptions per ask_local_batch call — one
# engine call per chunk, so the between-chunk time check bounds the budget
# overshoot to a single model call (~20s at observed rates)


def _is_yes(a: String) raises -> Bool:
    """True when the answer starts with yes/Yes/YES (ASCII, whitespace-tolerant).
    """
    var s = String(a.strip())
    if s.byte_length() < 3:
        return False
    var b = s.as_bytes()
    var c0 = Int(b[0]) | 32
    var c1 = Int(b[1]) | 32
    var c2 = Int(b[2]) | 32
    return c0 == 121 and c1 == 101 and c2 == 115  # 'y' 'e' 's'


def _engine_model() -> String:
    """The chat model the local engine reports on /v1/version ("unknown" when
    the probe fails). Aggregate-safe — a model name, never data."""
    try:
        var req = Request(method="GET", url="http://127.0.0.1:8000/v1/version")
        var client = HttpClient()
        var resp = client.send(req)
        var t = resp.text()
        var r = t.find('"model":"')
        if r == -1:
            return String("unknown")
        var rest = String(t[byte = r + 9 :])
        var q = rest.find('"')
        if q <= 0:
            return String("unknown")
        return String(rest[byte=:q])
    except:
        return String("unknown")


def _lower_prefix(s: String, n: Int) raises -> String:
    """The first `n` bytes of `s`, ASCII-lowercased (answers are ASCII)."""
    var b = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(b) and i < n:
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            c += 32
        out += chr(c)
        i += 1
    return out^


def _answer_kind(a: String) raises -> Int:
    """0 = yes · 1 = no · 2 = 'none' (the batch protocol's does-not-apply /
    unparsed fallback) · 3 = other. Separating these is what tells a real
    all-negative verdict apart from a protocol/parse failure: a wall of
    'none' means the answers never parsed (or the model chose the wrapper's
    escape hatch), NOT that the model judged every row a no."""
    var s = String(a.strip())
    if _is_yes(s):
        return 0
    if _lower_prefix(s, 4) == "none":
        return 2
    if _lower_prefix(s, 2) == "no":
        return 1
    return 3


def _pct(num: Int, den: Int) -> String:
    """num/den as 'NN.N%' ('n/a' when the denominator is 0)."""
    if den == 0:
        return String("n/a")
    var tenths = Int(Float64(num) * 1000.0 / Float64(den) + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10) + "%"


def _x10(num: Int, den: Int) -> String:
    """num/den with one decimal (e.g. a dedup factor '3.7')."""
    if den == 0:
        return String("n/a")
    var tenths = Int(Float64(num) * 10.0 / Float64(den) + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


def _secs1(ms: Float64) -> String:
    """Milliseconds -> seconds with one decimal."""
    var tenths = Int(ms / 100.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10) + "s"


def _per_sec(n: Int, ms: Float64) -> String:
    """Throughput n-per-second with one decimal."""
    if ms <= 0.0:
        return String("n/a")
    var tenths = Int(Float64(n) * 10000.0 / ms + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


def main() raises:
    progress("loading transactions")
    var rows = all_transactions()
    if len(rows) == 0:
        print_answer(
            "No transactions in the vault — index some statements first."
        )
        return

    # Distinct descriptions, first-seen order (the backfiller's dedup): classify
    # each description once, fan the verdict out to every row sharing it. Record
    # per-distinct truth (keyword tags are desc-deterministic, so the first row
    # seen carries the answer) for the balanced sample below.
    var seen = Dict[String, Int]()  # desc -> index into `distinct`
    var distinct = List[String]()
    var truth_by_id = List[Bool]()
    for i in range(len(rows)):
        if rows[i].desc not in seen:
            seen[rows[i].desc.copy()] = len(distinct)
            distinct.append(rows[i].desc.copy())
            var is_pos = False
            for t in range(len(rows[i].tags)):
                if rows[i].tags[t] == String(TRUTH_TAG):
                    is_pos = True
                    break
            truth_by_id.append(is_pos)

    # BALANCED sample: interleave tag-positive and tag-negative distinct
    # descriptions (first-seen order within each side), capped at MAX_DISTINCT.
    # Interleaving means a time-budget cutoff keeps the ~50/50 mix — a natural
    # low-base-rate vault no longer yields a sample with almost no positives.
    # When one side runs out, the rest fills from the other (reported below).
    var pos_ids = List[Int]()
    var neg_ids = List[Int]()
    for did in range(len(distinct)):
        if truth_by_id[did]:
            pos_ids.append(did)
        else:
            neg_ids.append(did)
    var sampled = List[String]()
    var sampled_ids = List[Int]()
    var pi = 0
    var ni = 0
    while len(sampled_ids) < MAX_DISTINCT and (
        pi < len(pos_ids) or ni < len(neg_ids)
    ):
        if pi < len(pos_ids):
            sampled_ids.append(pos_ids[pi])
            sampled.append(distinct[pos_ids[pi]].copy())
            pi += 1
        if len(sampled_ids) >= MAX_DISTINCT:
            break
        if ni < len(neg_ids):
            sampled_ids.append(neg_ids[ni])
            sampled.append(distinct[neg_ids[ni]].copy())
            ni += 1
    if len(pos_ids) == 0:
        progress(
            "note: no '"
            + String(TRUTH_TAG)
            + "'-tagged rows — the sample is negatives only"
        )

    progress(
        "classifying up to "
        + String(len(sampled))
        + " distinct descriptions on-device ("
        + String(TIME_BUDGET_S)
        + "s budget)"
    )
    var t0 = perf_counter_ns()
    var budget_s = Float64(TIME_BUDGET_S)  # runtime copy (0.0 = no cap)
    var answers = List[String]()
    var done = 0
    while done < len(sampled):
        var elapsed_s = Float64(perf_counter_ns() - t0) / 1.0e9
        if budget_s > 0.0 and elapsed_s >= budget_s and done > 0:
            progress(
                "time budget reached — evaluating the "
                + String(done)
                + " classified so far"
            )
            break
        var chunk = List[String]()
        var j = done
        while j < len(sampled) and j < done + CHUNK:
            chunk.append(sampled[j].copy())
            j += 1
        var res = ask_local_batch(String(QUESTION), chunk)
        for r in range(len(res)):
            answers.append(res[r].copy())
        done = j
        elapsed_s = Float64(perf_counter_ns() - t0) / 1.0e9
        var eta = String("")
        if done < len(sampled) and elapsed_s > 0.0:
            var left_s = Int(
                Float64(len(sampled) - done) * elapsed_s / Float64(done) + 0.5
            )
            eta = ", ~" + String(left_s) + "s for the rest"
        progress(
            "classified "
            + String(done)
            + "/"
            + String(len(sampled))
            + " distinct — "
            + String(Int(elapsed_s + 0.5))
            + "s elapsed"
            + eta
        )
    var elapsed_ms = Float64(perf_counter_ns() - t0) / 1.0e6

    # Model verdict per CLASSIFIED distinct-description id. Items past the time
    # budget get NO verdict (their rows are skipped below) — defaulting them to
    # "no" would fabricate false negatives.
    var verdict = Dict[Int, Bool]()
    for j in range(len(answers)):
        verdict[sampled_ids[j]] = _is_yes(String(answers[j]))

    # Row-level confusion vs the keyword tag, over rows whose description was
    # sampled. Row-level (not distinct-level) so a recurring charge counts the
    # number of times it actually appears — the operational reality.
    var tp = 0
    var fp = 0
    var fneg = 0
    var tn = 0
    var covered = 0
    for i in range(len(rows)):
        var did = seen[rows[i].desc]
        if did not in verdict:
            continue
        covered += 1
        var model_yes = verdict[did]
        var truth_yes = False
        for t in range(len(rows[i].tags)):
            if rows[i].tags[t] == String(TRUTH_TAG):
                truth_yes = True
                break
        if model_yes and truth_yes:
            tp += 1
        elif model_yes:
            fp += 1
        elif truth_yes:
            fneg += 1
        else:
            tn += 1

    var calls = (len(answers) + 9) // 10  # ask_local_batch groups ~10 per call
    var per_desc_ms = (
        elapsed_ms / Float64(len(answers)) if len(answers) > 0 else 0.0
    )

    var out = String("On-device classifier eval — aggregates only.\n")
    out += "Model: " + _engine_model() + "\n"
    out += (
        'Question: "'
        + String(QUESTION)
        + "\" vs the keyword tag '"
        + String(TRUTH_TAG)
        + "' as reference.\n\n"
    )
    out += (
        "Data: "
        + String(len(rows))
        + " transaction rows, "
        + String(len(distinct))
        + " distinct descriptions ("
        + _x10(len(rows), len(distinct))
        + "x dedup)"
    )
    var cls_pos = 0
    for j in range(len(answers)):
        if truth_by_id[sampled_ids[j]]:
            cls_pos += 1
    out += (
        "; classified "
        + String(len(answers))
        + " (balanced: "
        + String(cls_pos)
        + " tagged + "
        + String(len(answers) - cls_pos)
        + " untagged)"
    )
    if len(answers) < len(sampled):
        out += " — time-boxed at " + String(TIME_BUDGET_S) + "s"
    out += " covering " + String(covered) + " rows"
    out += "\n\nML (row-level, model vs keyword rule):\n"
    out += (
        "  agreement "
        + _pct(tp + tn, covered)
        + "   precision "
        + _pct(tp, tp + fp)
        + "   recall "
        + _pct(tp, tp + fneg)
        + "   F1 "
        + _pct(2 * tp, 2 * tp + fp + fneg)
        + "\n"
    )
    out += (
        "  confusion: TP "
        + String(tp)
        + "  FP "
        + String(fp)
        + "  FN "
        + String(fneg)
        + "  TN "
        + String(tn)
        + "   base rate "
        + _pct(tp + fneg, covered)
        + "\n"
    )
    out += (
        "  (keyword tags are imperfect truth — a disagreement is model-vs-rule,"
        " not a certified model error; the sample is BALANCED, so base rate +"
        " agreement reflect the sample, not the vault)\n"
    )
    # The raw answer mix — the diagnostic that separates "the model said no to
    # everything" (mostly `no`) from "the batch protocol failed / the model took
    # the wrapper's 'none' escape hatch" (mostly `none`).
    var n_yes = 0
    var n_no = 0
    var n_none = 0
    var n_other = 0
    for j in range(len(answers)):
        var kind = _answer_kind(String(answers[j]))
        if kind == 0:
            n_yes += 1
        elif kind == 1:
            n_no += 1
        elif kind == 2:
            n_none += 1
        else:
            n_other += 1
    out += (
        "  answer mix: "
        + String(n_yes)
        + " yes · "
        + String(n_no)
        + " no · "
        + String(n_none)
        + " none · "
        + String(n_other)
        + " other\n"
    )
    if n_yes == 0 and n_none > n_no:
        out += (
            "  ⚠ mostly 'none' — the numbered replies didn't parse or the model"
            " used the batch wrapper's 'does not apply' escape instead of"
            " yes/no. Inspect one raw exchange in the run capture before"
            " trusting the ML numbers.\n"
        )
    out += "\nOperational:\n"
    out += (
        "  "
        + String(len(answers))
        + " descriptions in ~"
        + String(calls)
        + " model calls (batched ~10/call), "
        + _secs1(elapsed_ms)
        + " total\n"
    )
    out += (
        "  "
        + _per_sec(len(answers), elapsed_ms)
        + " distinct/s  ·  "
        + _per_sec(covered, elapsed_ms)
        + " rows/s effective after dedup fan-out  ·  ~"
        + String(Int(per_desc_ms + 0.5))
        + "ms per distinct description\n"
    )
    print_answer(out)
