"""Generate the demo vault — a few synthetic, text-layer PDF documents you can
drop into a veilens vault to try the end-to-end flow without your own data.

These mimic what you'd export from a bank/insurer portal: real *digital* PDFs
with a selectable text layer (so pdftotext.mojo extracts them — no OCR). All data
is fictional. Run:  python3 -m pip install fpdf2 && python3 make_samples.py

Outputs into ./vault/:
  statement-2025-03.pdf  statement-2025-04.pdf  — checking-account statements
  auto-insurance.pdf                            — policy w/ a renewal date
  vehicle-registration.pdf                      — incl. a license plate

Answerable demo questions:
  "How much did I spend on travel in 2025?"   -> sums the travel rows
  "When does my car insurance renew?"          -> 2026-09-15
  "What is my license plate?"                   -> 8ABC123
"""

import os

from fpdf import FPDF

OUT = os.path.join(os.path.dirname(__file__), "vault")


def statement(path: str, period: str, rows: list[tuple[str, str, str, str]]) -> None:
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "Riverbank Federal Credit Union", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 11)
    pdf.cell(0, 7, "Checking Account Statement", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 7, f"Account: ****4417    Statement period: {period}", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)
    pdf.set_font("Helvetica", "B", 10)
    pdf.cell(28, 8, "Date")
    pdf.cell(86, 8, "Description")
    pdf.cell(34, 8, "Category")
    pdf.cell(28, 8, "Amount", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    total = 0.0
    for date, desc, cat, amt in rows:
        pdf.cell(28, 7, date)
        pdf.cell(86, 7, desc)
        pdf.cell(34, 7, cat)
        pdf.cell(28, 7, amt, new_x="LMARGIN", new_y="NEXT")
        total += float(amt.replace("$", "").replace(",", ""))
    pdf.ln(2)
    pdf.set_font("Helvetica", "B", 10)
    pdf.cell(148, 8, "Total debits")
    pdf.cell(28, 8, f"${total:,.2f}", new_x="LMARGIN", new_y="NEXT")
    pdf.output(path)


def insurance(path: str) -> None:
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "Meridian Auto Insurance", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 11)
    for line in [
        "Policy declarations page",
        "",
        "Policy number: MA-2231-88",
        "Insured: A. Riverton",
        "Vehicle: 2021 Subaru Outback",
        "Coverage: Liability + Collision + Comprehensive",
        "Premium: $1,284.00 / year",
        "",
        "Policy effective: 2025-09-15",
        "Policy renews on: 2026-09-15",
    ]:
        pdf.cell(0, 7, line, new_x="LMARGIN", new_y="NEXT")
    pdf.output(path)


def registration(path: str) -> None:
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "State of Cascadia - Vehicle Registration", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 11)
    for line in [
        "",
        "License plate: 8ABC123",
        "Make / Model: Subaru Outback",
        "Year: 2021",
        "VIN: 4S4BTAEC5M3100001",
        "Registered owner: A. Riverton",
        "Expires: 2026-04-30",
    ]:
        pdf.cell(0, 7, line, new_x="LMARGIN", new_y="NEXT")
    pdf.output(path)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    statement(
        os.path.join(OUT, "statement-2025-03.pdf"),
        "March 2025",
        [
            ("2025-03-03", "UNITED AIRLINES", "travel", "$412.40"),
            ("2025-03-09", "BLUE BOTTLE COFFEE", "dining", "$6.75"),
            ("2025-03-15", "HILTON SEATTLE", "travel", "$268.10"),
            ("2025-03-21", "TRADER JOE'S", "groceries", "$83.22"),
            ("2025-03-28", "SHELL GAS", "auto", "$54.00"),
        ],
    )
    statement(
        os.path.join(OUT, "statement-2025-04.pdf"),
        "April 2025",
        [
            ("2025-04-02", "DELTA AIR LINES", "travel", "$331.00"),
            ("2025-04-06", "WHOLE FOODS", "groceries", "$112.49"),
            ("2025-04-14", "MARRIOTT PORTLAND", "travel", "$204.88"),
            ("2025-04-19", "NETFLIX", "subscriptions", "$15.49"),
            ("2025-04-25", "CHEVRON", "auto", "$48.30"),
        ],
    )
    insurance(os.path.join(OUT, "auto-insurance.pdf"))
    registration(os.path.join(OUT, "vehicle-registration.pdf"))
    print("wrote demo vault ->", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)


if __name__ == "__main__":
    main()
