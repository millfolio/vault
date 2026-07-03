# Prompt eval — pre-release codegen quality gate

`privacy_box-system.md` is the system prompt the **frontier model** follows to write
the Mojo program that answers a vault question. It's an LLM behaviour, so you can't
unit-test it — you need to *run* codegen and inspect what the model produces. This is
that harness.

It exists because of the **"$224,303 phone bill"** class of bug: the model wrote a
program that summed amounts over `search()` chunks (folding in running balances and
printed totals) and printed a raw float. The fix was in the prompt (steer
category/total spending to `transactions()` + `money()`, never `.alias`). This eval
guards that fix.

## Two tiers (and why only one is here, in CI-able form)

1. **Program-shape lint (this harness — stable).** Drive codegen, then assert the
   *generated program* uses the right tools / shape: `transactions(` and `money(` for
   spending; `manifest(` for vault-structure questions; and NEVER `.alias`
   (a compile error — the field is `.id`), `search(` for exact aggregates, or
   `"$" +`/`String(total)` money formatting. The model picking the right shape is far
   less flaky than it getting the arithmetic perfect, so this is the durable signal.
   - **Spec typed-money guard** (COMPUTE_VS_RENDER Phase 2, applied to every case —
     not a golden row). Money in result DATA must be TYPED through `money_val(`. A
     *bare float* can't even reach a builder — `Cell` has no `Float64` constructor, so
     `kpi("x", 12.5)` is a COMPILE error the build loop already rejects (the type
     system enforces that half). The COMPILABLE violation is handing a builder VALUE a
     pre-formatted `money()` STRING, which slips in as an untyped text cell (no raw
     number → the client can't scale an axis or re-aggregate); the guard flags a
     `money(` (not `money_val(`) after the first comma of a `kpi(`/`.row(`/`.point(`
     call. A `money()` in the narrative `print_answer`/`result_text` or in a builder's
     leading LABEL is unaffected. The Phase-2 golden rows ("show my spending by month"
     → `series`, "…dashboard…" → `kpi`, "top merchants" → `table`) exercise the
     builders on real generated programs so the guard runs against live output.
2. **Answer accuracy (not yet automated).** Run the program end-to-end against a
   fixture vault with known totals and check the number. This needs an indexed
   fixture + a live engine, and is model-nondeterministic, so it belongs in a
   periodic/manual deep eval reported as a pass-rate — not a hard gate. See TODO below.

## How it works

Codegen only ever sees the **aliased manifest** (never real data), so the lint feeds a
hand-written synthetic manifest (`manifests/*.txt`) and a question to the new
`privacy_box codegen "<q>" --manifest <file>` subcommand — **no index or embedding
server required, only the frontier key.**

- `golden.<model>.tsv` — one row per case: `question <TAB> must_contain <TAB>
  must_not_contain <TAB> manifest`. The contain-lists are comma-separated literal
  substrings. **The golden set is PER-MODEL** — codegen quality is a property of the
  (prompt, model) pair, so each served model has its own file (e.g.
  `golden.claude-sonnet-5.tsv`, `golden.claude-sonnet-4-6.tsv`).
- `fixtures/data/categories.txt` — the FIXTURE tag registry. `run_eval.sh` copies
  `fixtures/data` to a temp `MILLFOLIO_DATA_DIR` so codegen sees a fixed, known tag
  set — never your real categories, and the eval never mutates them.
- `run_eval.sh [MODEL]` — runs each case (with `PRIVACY_BOX_MODEL=<MODEL>`) and greps
  the program for the rules; prints `PASS`/`FAIL <reasons>` + a summary, exit non-zero
  on any failure. Model = `$1` or `$EVAL_MODEL`, default `claude-sonnet-5`.
- `run_eval_test.sh` — mock-driven UNIT TESTS for the harness itself (no key, no
  model, no network); asserts the lint contract so `run_eval.sh` can't silently rot.
  Runs in `:check` via `moon run vault:eval-selftest`.

## Run it

```bash
export ANTHROPIC_API_KEY=sk-...              # else codegen falls back to the LOCAL model
moon run vault:eval                          # default model (claude-sonnet-5)
moon run vault:eval -- claude-sonnet-4-6     # a specific model → golden.claude-sonnet-4-6.tsv
EVAL_VERBOSE=1 moon run vault:eval           # print the generated program for each FAIL
```

Add a case: append a row to the relevant `golden.<model>.tsv` (and a manifest under
`manifests/` if you need a new file shape). Introducing a model: copy the closest
golden to `golden.<new-model>.tsv`. Keep rules to **shape**, not exact wording, so
they survive the model's phrasing variance.

## TODO — accuracy tier

Add a fixture vault (synthetic statements with known arithmetic — seed from
`core/test/extract/transactions_test.mojo`), index it, run `privacy_box vault` per
question, and assert the printed total is within tolerance. Report as a pass-rate over
N runs (nondeterministic), gated behind a flag so it never blocks a commit.
