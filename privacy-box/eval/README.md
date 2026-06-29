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
2. **Answer accuracy (not yet automated).** Run the program end-to-end against a
   fixture vault with known totals and check the number. This needs an indexed
   fixture + a live engine, and is model-nondeterministic, so it belongs in a
   periodic/manual deep eval reported as a pass-rate — not a hard gate. See TODO below.

## How it works

Codegen only ever sees the **aliased manifest** (never real data), so the lint feeds a
hand-written synthetic manifest (`manifests/*.txt`) and a question to the new
`privacy_box codegen "<q>" --manifest <file>` subcommand — **no index or embedding
server required, only the frontier key.**

- `golden.tsv` — one row per case: `question <TAB> must_contain <TAB> must_not_contain
  <TAB> manifest`. The contain-lists are comma-separated literal substrings.
- `run_eval.sh` — runs each case and greps the program for the rules; prints
  `PASS`/`FAIL <reasons>` and a summary, exit non-zero on any failure.

## Run it

```bash
export ANTHROPIC_API_KEY=sk-...      # else codegen falls back to the LOCAL model
moon run vault:eval                  # or: (cd vault && pixi run eval)
EVAL_VERBOSE=1 pixi run eval          # print the generated program for each FAIL
```

Add a case: append a row to `golden.tsv` (and a manifest under `manifests/` if you
need a new file shape). Keep rules to **shape**, not exact wording, so they survive
the model's phrasing variance.

## TODO — accuracy tier

Add a fixture vault (synthetic statements with known arithmetic — seed from
`core/test/extract/transactions_test.mojo`), index it, run `privacy_box vault` per
question, and assert the printed total is within tolerance. Report as a pass-rate over
N runs (nondeterministic), gated behind a flag so it never blocks a commit.
