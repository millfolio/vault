# Synthetic fixture vault

The demo's data — **synthetic, public-safe, obviously-fake PII**. This is what the
replayed programs run over, so it must be stable (the cached programs reference its
aliases).

```
fixtures/
  vault/        the synthetic source files the demo indexes (fake PDF/CSV statements)
  index/        the pre-built on-device index for vault/ (chunks.tsv, manifest.tsv,
                transactions.tsv, index.db) — copied into ~/.config/millfolio at deploy
```

## Building the fixtures

1. **Generate fake statements** in `vault/` — fictional names/accounts/amounts.
   Reuse the layout the real extractor understands (a Wells-Fargo-style checking
   statement with date / description / deposit / withdrawal / running-balance
   columns) so `transactions()` reconciles and the demo answers are exact.
2. **Index them** with the real indexer (`mill index fixtures/vault`, or the
   `build/vault index` binary), which builds chunks + embeddings + the reconciled
   `transactions.tsv`. Capture the resulting `~/.config/millfolio` into `index/`.
3. **Verify** reconciliation closed (so count/total/biggest are exact):
   `transactions.tsv` should be non-empty for the statement files.

At deploy, `run-demo.sh`-style setup points `MILLFOLIO_VAULT` at `vault/` and stages
`index/` into the demo account's `~/.config/millfolio`.

## Why this matters

Curate the demo questions around what reconciles here, so replayed programs hit the
deterministic `transactions()`/`manifest()` path → no model calls → real execution
that scales and is identical every visit. Keep the fixture set small and the
aliases stable so the priming cache stays valid.

> TODO: add a generator script (`scripts/build-fixtures.sh`) that emits the fake
> statements deterministically. A PDF generator (or reusing real statement *layout*
> with fictional data) is the main remaining piece.
