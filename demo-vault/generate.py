#!/usr/bin/env python3
"""generate.py — synthetic, public-safe demo vault for millfolio.

Everything here is FICTIONAL — fake bank, fake people, fake amounts. It produces a
small vault that exercises the real product end to end:

  - two checking-account statements whose transactions RECONCILE (a beginning
    balance + a running-balance column + printed Deposits/Withdrawals totals that
    close), so `transactions()` returns exact, verified data — count / total /
    biggest answer with no model guesswork;
  - an auto-insurance declarations page (a "when does my insurance renew?" lookup);
  - a vehicle registration (a "what's my license plate?" lookup).

The statement layout places date / description / deposit / withdrawal / running-
balance in DISTINCT x-columns (points), exactly what the extractor's layout pass +
column-direction reconciler need. Deterministic output → the demo's replay cache
stays valid. Run:  python3 -m pip install fpdf2 && python3 generate.py
"""

import os
from fpdf import FPDF

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vault")

# Column x-positions (points; Letter = 612 wide). Right edges for the money columns
# (statements right-align amounts) — the reconciler keys direction off these columns.
X_DATE, X_DESC = 40, 95
X_DEP_R, X_WD_R, X_BAL_R = 380, 470, 565   # right edges of Deposits / Withdrawals / Balance


def _money(x):
    return f"{x:,.2f}"


class Stmt(FPDF):
    def header_block(self, bank, acct, period):
        self.set_font("Helvetica", "B", 15)
        self.set_xy(40, 36); self.cell(0, 16, bank)
        self.set_font("Helvetica", "", 10)
        self.set_xy(40, 54); self.cell(0, 12, "Checking Account Statement")
        self.set_xy(40, 68); self.cell(0, 12, f"Account: ****4417    Statement period: {period}")

    def right(self, x_right, y, text):
        self.set_font("Courier", "", 9)
        w = self.get_string_width(text)
        self.set_xy(x_right - w, y); self.cell(w, 11, text)

    def left(self, x, y, text, bold=False):
        self.set_font("Courier", "B" if bold else "", 9)
        self.set_xy(x, y); self.cell(0, 11, text)


def statement(path, bank, period, begin, txns):
    """txns: list of (date, desc, amount, 'deposit'|'withdrawal'). Renders a
    reconciling statement and returns the computed (deposits, withdrawals, ending)."""
    pdf = Stmt(unit="pt", format="letter")
    pdf.add_page()
    pdf.header_block(bank, "****4417", period)

    y = 96
    pdf.left(X_DATE, y, "Account summary", bold=True); y += 16
    pdf.left(X_DESC, y, "Beginning balance"); pdf.right(X_BAL_R, y, _money(begin)); y += 22

    pdf.left(X_DATE, y, "Date", bold=True)
    pdf.left(X_DESC, y, "Description", bold=True)
    pdf.right(X_DEP_R, y, "Additions"); pdf.right(X_WD_R, y, "Subtractions"); pdf.right(X_BAL_R, y, "Balance")
    y += 14

    bal = begin
    deposits = 0.0
    withdrawals = 0.0
    for (date, desc, amt, direction) in txns:
        pdf.left(X_DATE, y, date)
        pdf.left(X_DESC, y, desc)
        if direction == "deposit":
            bal += amt; deposits += amt
            pdf.right(X_DEP_R, y, _money(amt))
        else:
            bal -= amt; withdrawals += amt
            pdf.right(X_WD_R, y, _money(amt))
        pdf.right(X_BAL_R, y, _money(bal))      # running balance on every row
        y += 13

    ending = begin + deposits - withdrawals
    y += 12
    pdf.left(X_DESC, y, "Deposits/Additions"); pdf.right(X_BAL_R, y, _money(deposits)); y += 13
    pdf.left(X_DESC, y, "Withdrawals/Subtractions"); pdf.right(X_BAL_R, y, _money(withdrawals)); y += 13
    pdf.left(X_DESC, y, "Ending balance"); pdf.right(X_BAL_R, y, _money(ending))
    pdf.output(path)
    assert abs(bal - ending) < 0.005, (bal, ending)
    return deposits, withdrawals, ending


def insurance(path):
    pdf = FPDF(unit="pt", format="letter"); pdf.add_page()
    pdf.set_font("Helvetica", "B", 15); pdf.set_xy(40, 40); pdf.cell(0, 16, "Meridian Auto Insurance")
    pdf.set_font("Helvetica", "", 11); y = 70
    for line in ["Policy declarations page", "", "Policy number: MA-2231-88",
                 "Insured: Alex Rivera", "Vehicle: 2021 Subaru Outback",
                 "Coverage: Liability + Collision + Comprehensive",
                 "Premium: $1,284.00 / year", "", "Policy effective: 2026-01-15",
                 "Policy renews on: 2027-01-15"]:
        pdf.set_xy(40, y); pdf.cell(0, 14, line); y += 16
    pdf.output(path)


def registration(path):
    pdf = FPDF(unit="pt", format="letter"); pdf.add_page()
    pdf.set_font("Helvetica", "B", 15); pdf.set_xy(40, 40); pdf.cell(0, 16, "State Department of Motor Vehicles")
    pdf.set_font("Helvetica", "", 11); y = 70
    for line in ["Vehicle Registration", "", "Owner: Alex Rivera",
                 "Vehicle: 2021 Subaru Outback", "VIN: 4S4BTAFC1M3201144",
                 "License plate: 8XKT219", "Registration expires: 2026-11-30"]:
        pdf.set_xy(40, y); pdf.cell(0, 14, line); y += 16
    pdf.output(path)


# Six months (Feb–Jul 2026) of recurring merchant activity, so a "weekly amounts
# per merchant over the last 6 months / top-10 by spend" question has real data:
# recurring bills every month + weekly discretionary spend across ~14 merchants.
# Every amount is fixed (deterministic → the replay cache stays valid). `dd` day is
# a plain calendar day; each month a payroll deposit twice keeps the balance healthy.
_DAYS = {2: 28, 3: 31, 4: 30, 5: 31, 6: 30, 7: 31}


def _month_txns(m):
    """Deterministic transactions for month `m` (2..7). Amounts vary slightly by month
    (via `m`) so the weekly lines aren't flat, but every merchant recurs."""
    v = m - 2  # 0..5, a small per-month drift
    t = [
        (f"{m}/03", "Acme Payroll Direct Deposit", 2800.00, "deposit"),
        (f"{m}/17", "Acme Payroll Direct Deposit", 2800.00, "deposit"),
        (f"{m}/02", "Riverbank Mortgage Payment", 1650.00, "withdrawal"),
        (f"{m}/05", "Corner Market", 78.40 + v * 3.10, "withdrawal"),
        (f"{m}/12", "Corner Market", 64.15 + v * 2.20, "withdrawal"),
        (f"{m}/24", "Corner Market", 91.05 + v * 1.75, "withdrawal"),
        (f"{m}/08", "Grocery Outlet", 96.30 - v * 2.40, "withdrawal"),
        (f"{m}/21", "Grocery Outlet", 71.88 + v * 3.30, "withdrawal"),
        (f"{m}/04", "Sunrise Cafe", 14.75 + v * 0.50, "withdrawal"),
        (f"{m}/11", "Sunrise Cafe", 12.10 + v * 0.40, "withdrawal"),
        (f"{m}/25", "Sunrise Cafe", 16.20 + v * 0.35, "withdrawal"),
        (f"{m}/09", "City Power & Light", 128.20 + v * 4.80, "withdrawal"),
        (f"{m}/15", "Metro Water District", 44.50 + v * 1.20, "withdrawal"),
        (f"{m}/06", "Fuel Depot", 47.60 + v * 2.10, "withdrawal"),
        (f"{m}/20", "Fuel Depot", 52.30 - v * 1.10, "withdrawal"),
        (f"{m}/03", "Cloud Stream Media", 17.99, "withdrawal"),
        (f"{m}/03", "Tunes Music", 10.99, "withdrawal"),
        (f"{m}/12", "Metro Transit Pass", 60.00, "withdrawal"),
        (f"{m}/14", "Bella Trattoria", 58.40 + v * 2.60, "withdrawal"),
        (f"{m}/27", "Noodle House", 32.15 + v * 1.40, "withdrawal"),
        # health / phone / insurance / fitness — monthly signal for those tags
        (f"{m}/07", "Lakeside Pharmacy", 23.85 + v * 0.90, "withdrawal"),
        (f"{m}/10", "Horizon Wireless", 82.50, "withdrawal"),
        (f"{m}/13", "Northwind Auto Insurance", 118.75, "withdrawal"),
        (f"{m}/16", "Iron Works Gym", 39.00, "withdrawal"),
        (f"{m}/22", "Whisker & Paw Pet Supply", 31.60 + v * 1.15, "withdrawal"),
        # the credit-card payment — exercises the transfers guard (spending()
        # must EXCLUDE it, so card purchases aren't double counted). The
        # descriptor must match the DEFAULT transfers keywords (ach/transfer/
        # zelle/venmo/wire) or the guard never fires and the payment pollutes
        # "top merchants" — which is exactly what the first cut did.
        (f"{m}/26", "Card Services Payment - ACH Transfer", 240.00 + v * 35.00, "withdrawal"),
    ]
    # A few one-off larger purchases scattered across the half-year (so the top-10 by
    # spend has a long tail beyond the recurring bills).
    extras = {
        2: [("2/19", "Blue Bottle Hardware", 214.30, "withdrawal")],
        3: [("3/22", "Bright Smile Dental", 185.00, "withdrawal"),
            ("3/28", "State Tax Refund", 431.00, "deposit")],
        4: [("4/26", "Summit Auto Repair", 612.50, "withdrawal")],
        5: [("5/16", "Harbor View Hotel", 342.80, "withdrawal"),
            ("5/17", "Grand Stage Theater", 96.00, "withdrawal")],
        6: [("6/10", "North Ridge Outfitters", 289.99, "withdrawal")],
        7: [("7/08", "Blue Bottle Hardware", 176.45, "withdrawal"),
            ("7/15", "Pine & Page Booksellers", 47.25, "withdrawal")],
    }
    t += extras.get(m, [])
    # Order by day so the running balance reads naturally.
    return sorted(t, key=lambda r: int(r[0].split("/")[1]))


def card_csv(path):
    """A credit-card export whose descriptors carry a trailing LOCATION (city STATE
    COUNTRY), so `.country`/`.state` populate and a "spending by state/country" map
    has data. Description column = the raw card descriptor; positive Amount = a
    purchase (debit). Deterministic. Spans several US states + two countries."""
    rows = [
        # date, raw card descriptor (with trailing location), amount
        ("05/03/2026", "APPLE STORE R042 CUPERTINO CA USA", 1299.00),
        ("05/06/2026", "STARBUCKS STORE 04821 SEATTLE WA USA", 6.45),
        ("05/09/2026", "WHOLE FOODS MKT 10233 PORTLAND OR USA", 84.12),
        ("05/12/2026", "SHELL OIL 57721456 AUSTIN TX USA", 52.80),
        ("05/15/2026", "CHIPOTLE 1123 NEW YORK NY USA", 14.75),
        ("05/19/2026", "TARGET 00042 CHICAGO IL USA", 96.30),
        ("05/23/2026", "STARBUCKS STORE 04821 SEATTLE WA USA", 5.95),
        ("05/28/2026", "DELTA AIR LINES 0068 ATLANTA GA USA", 412.20),
        ("06/02/2026", "APPLE STORE R042 CUPERTINO CA USA", 249.00),
        ("06/07/2026", "WHOLE FOODS MKT 10233 PORTLAND OR USA", 73.44),
        ("06/11/2026", "TESCO STORES 3421 LONDON GBR", 42.18),
        ("06/14/2026", "CAFE DE FLORE PARIS FRA", 28.60),
        ("06/18/2026", "SHELL OIL 57721456 AUSTIN TX USA", 48.35),
        ("06/22/2026", "CHIPOTLE 1123 NEW YORK NY USA", 16.20),
        ("06/26/2026", "STARBUCKS STORE 04821 SEATTLE WA USA", 7.10),
        ("07/01/2026", "TARGET 00042 CHICAGO IL USA", 61.05),
        ("07/04/2026", "WHOLE FOODS MKT 55120 SAN FRANCISCO CA USA", 58.90),
        ("07/07/2026", "SHELL OIL 57721456 AUSTIN TX USA", 51.40),
        ("05/08/2026", "CVS PHARMACY 08841 DENVER CO USA", 32.15),
        ("05/21/2026", "HILTON HOTELS PORTLAND OR USA", 289.40),
        ("05/26/2026", "PANERA BREAD 2210 BOSTON MA USA", 18.65),
        ("06/04/2026", "UNITED AIRLINES 0016 DENVER CO USA", 386.70),
        ("06/09/2026", "CVS PHARMACY 08841 DENVER CO USA", 21.40),
        ("06/16/2026", "RAMEN YOKOCHO TOKYO JPN", 34.90),
        ("06/24/2026", "TRADER JOES 118 SEATTLE WA USA", 67.25),
        ("06/29/2026", "AMC THEATRES 0446 CHICAGO IL USA", 42.50),
        ("07/02/2026", "CVS PHARMACY 08841 DENVER CO USA", 27.80),
        ("07/06/2026", "BLUE LAGOON SPA REYKJAVIK ISL", 118.00),
        ("07/09/2026", "TRADER JOES 118 SEATTLE WA USA", 54.60),
        ("07/11/2026", "STARBUCKS STORE 04821 SEATTLE WA USA", 6.85),
    ]
    with open(path, "w") as f:
        f.write("Transaction Date,Description,Type,Amount\n")
        for (d, desc, amt) in rows:
            f.write(f"{d},{desc},Purchase,{amt:.2f}\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    card_csv(os.path.join(OUT, "credit-card-2026.csv"))
    bal = 2450.00
    for m in range(2, 8):  # Feb..Jul 2026
        period = f"{m:02d}/01/2026 - {m:02d}/{_DAYS[m]}/2026"
        _, _, ending = statement(
            os.path.join(OUT, f"statement-2026-{m:02d}.pdf"),
            "Riverbank Federal Credit Union", period, bal, _month_txns(m))
        bal = ending  # chain: next month begins where this one ended
    insurance(os.path.join(OUT, "auto-insurance.pdf"))
    registration(os.path.join(OUT, "vehicle-registration.pdf"))
    print("wrote synthetic vault to", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f)


if __name__ == "__main__":
    main()
