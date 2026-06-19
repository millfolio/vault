# Demo vault

A few **synthetic, text-layer** PDF documents you can drop into a millfolio vault
to try the end-to-end flow without using your own financial data. They mimic what
you'd export from a bank/insurer portal — real *digital* PDFs with a selectable
text layer, so [pdftotext.mojo](https://github.com/millrace/pdftotext.mojo)
extracts them directly (no OCR). **All data is fictional.**

`vault/`:
- `statement-2025-03.pdf`, `statement-2025-04.pdf` — checking-account statements
  with travel / dining / groceries transactions
- `auto-insurance.pdf` — a policy declarations page with a renewal date
- `vehicle-registration.pdf` — includes a license plate

Questions they can answer (validated end-to-end):
- *"How much did I spend on travel in 2025?"*
- *"When does my car insurance renew?"* → 2026-09-15
- *"What is my license plate?"* → 8ABC123

Regenerate with:

```sh
python3 -m pip install fpdf2
python3 make_samples.py
```
