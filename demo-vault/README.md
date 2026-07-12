# millfolio demo-vault

> 💬 **Community:** questions, ideas, and show-and-tell live in [GitHub Discussions](https://github.com/millfolio/millfolio/discussions).

The **synthetic, public-safe** vault the millfolio demo runs over. Everything is
**fictional** — fake bank (Riverbank Federal Credit Union), fake person (Alex
Rivera), fake accounts/amounts/plates. No real data, ever.

`generate.py` (deterministic; needs `fpdf2`) writes `vault/`:

| file | what it demonstrates |
|---|---|
| `statement-2026-03.pdf`, `statement-2026-04.pdf` | checking statements that **reconcile** — a beginning balance + a running-balance column + printed Deposits/Withdrawals totals that close → `transactions()` returns exact, verified data (count / total / biggest with no model guesswork) |
| `auto-insurance.pdf` | "when does my insurance renew?" (a content lookup) |
| `vehicle-registration.pdf` | "what's my license plate?" (a content lookup) |

The statements place date / description / deposit / withdrawal / running-balance in
distinct x-columns (points), exactly what the extractor's layout pass + the
column-direction reconciler need.

```bash
python3 -m pip install fpdf2
python3 generate.py            # → vault/*.pdf
```

Deterministic output keeps the demo's replay cache valid. To grow the demo, add
more fictional statements/docs here and regenerate. Consumed by the `demo` repo
(it points `MILLFOLIO_VAULT` at `vault/` and indexes it).

> Reconciliation is DERIVED by `statement()` from the transaction list (the
> printed Deposits/Withdrawals totals + running balance always close), so
> adding rows can't break it — regenerate and re-index after any change.
