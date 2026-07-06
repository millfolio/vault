"""all_transactions() / spending() — the whole-vault transaction helpers, driven
end-to-end over a hermetically-built index. `pixi run test-spending`.

Guards the two tool-surface helpers a generated program uses instead of
hand-writing the outer `manifest()` → per-file `transactions()` loop:

  * `all_transactions()` == the UNION of `transactions(f.alias)` over `manifest()`
    (concatenation, nothing dropped, nothing double-counted).
  * `spending()` == `all_transactions()` restricted to PURCHASES — `direction ==
    "debit"` AND NOT tagged `transfers`: it keeps ordinary debits, excludes credits,
    and excludes a debit that carries the `transfers` tag (the belt-and-suspenders
    transfers guard — the real categorizer only tags credits `transfers`, so the
    excluded-debit branch is exercised with a SYNTHETIC row appended to the persisted
    transactions.tsv).

Builds a real index via `build_index` under the `MILLFOLIO_FAKE_EMBED` hook
(deterministic unit vectors, no embed endpoint) + a pinned `MILLFOLIO_DATA_DIR`,
from hand-written CSV fixtures (no private data). The default tag registry has no
ML rules, so no model call is made."""

from std.os import getenv, makedirs
from std.os.path import exists

from vault.index.index import build_index
from vault.tools.tools import manifest, transactions, all_transactions, spending
from vault.derive.tags import txns_path


comptime FAKE_URL = "http://127.0.0.1:1/v1"
comptime SYNTH_DESC = "SYNTHETIC XFER GUARD"


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _write(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def _read(path: String) raises -> String:
    if not exists(path):
        return String("")
    with open(path, "r") as f:
        return f.read()


def _has_tag(tags: List[String], name: String) -> Bool:
    for i in range(len(tags)):
        if tags[i] == name:
            return True
    return False


def main() raises:
    var dd = String(getenv("MILLFOLIO_DATA_DIR", "").strip())
    expect(dd != "", "MILLFOLIO_DATA_DIR must be set by the test task")
    expect(
        getenv("MILLFOLIO_FAKE_EMBED", "") != "",
        "MILLFOLIO_FAKE_EMBED must be set by the test task",
    )
    makedirs(dd, exist_ok=True)

    # ── fixtures: 3 debit purchases + 1 credit (payroll) across two CSVs ─────────
    var vault = dd + "/vault"
    makedirs(vault, exist_ok=True)
    _write(
        vault + "/a.csv",
        String("Transaction Date,Description,Type,Amount (USD)\n")
        + "01/15/2026,STARBUCKS STORE 04821 SEATTLE WA USA,Purchase,4.50\n"
        + "02/03/2026,WHOLE FOODS MKT SEATTLE WA USA,Purchase,56.78\n",
    )
    _write(
        vault + "/b.csv",
        String("Transaction Date,Description,Type,Amount (USD)\n")
        + "03/20/2026,SAFEWAY 3031 DALY CITY CA USA,Purchase,12.34\n"
        + "03/22/2026,ACH TRANSFER PAYROLL DEPOSIT,Payment,-100.00\n",
    )

    build_index([vault], FAKE_URL)

    # ── 1) all_transactions() == the UNION of per-file transactions() ───────────
    var files = manifest()
    var union = 0
    for i in range(len(files)):
        union += len(transactions(String(files[i].alias)))
    var everything = all_transactions()
    expect(
        len(everything) == union,
        "all_transactions() length == sum of per-file transactions()",
    )
    expect(len(everything) == 4, "4 transactions across a.csv + b.csv")

    # ── 2) spending() keeps ordinary debits, excludes the credit ────────────────
    # Independently derive the expected purchase subset from all_transactions().
    var want_debits = 0
    var credits = 0
    for i in range(len(everything)):
        ref x = everything[i]
        if x.direction == "debit" and not _has_tag(x.tags, "transfers"):
            want_debits += 1
        elif x.direction == "credit":
            credits += 1
    expect(credits >= 1, "the fixture has at least one credit (payroll)")

    var spend = spending()
    expect(
        len(spend) == want_debits,
        "spending() count == debits-not-transfers in all_transactions()",
    )
    # Every row spending() returns is a purchase (debit, not tagged transfers).
    for i in range(len(spend)):
        ref x = spend[i]
        expect(x.direction == "debit", "spending() row is a debit")
        expect(
            not _has_tag(x.tags, "transfers"),
            "spending() row is not tagged transfers",
        )
    # The credit is excluded — no spending() row carries the credit's direction.
    for i in range(len(spend)):
        expect(spend[i].direction != "credit", "spending() excludes credits")

    # ── 3) transfers exclusion on a DEBIT: inject a synthetic debit+transfers row ─
    # The real categorizer only tags credits `transfers` (direction-gated), so we
    # append a debit row carrying the `transfers` tag straight into the persisted
    # side-table to exercise spending()'s belt-and-suspenders exclusion branch.
    # 13 tab-separated columns: falias date amount direction desc tags added_gen
    #   year merchant country state city zip (trailing location cols empty).
    var line = (
        String("file_0\t2026-04-01\t99.00\tdebit\t")
        + SYNTH_DESC
        + "\ttransfers\t1\t2026\t\t\t\t\t\n"
    )
    _write(txns_path(), _read(txns_path()) + line)

    var everything2 = all_transactions()
    expect(
        len(everything2) == len(everything) + 1,
        "all_transactions() now includes the injected debit+transfers row",
    )
    var saw_synth_all = False
    for i in range(len(everything2)):
        if everything2[i].desc == SYNTH_DESC:
            saw_synth_all = True
    expect(saw_synth_all, "the injected row IS in all_transactions()")

    var spend2 = spending()
    var saw_synth_spend = False
    for i in range(len(spend2)):
        if spend2[i].desc == SYNTH_DESC:
            saw_synth_spend = True
    expect(
        not saw_synth_spend,
        "spending() EXCLUDES the injected debit+transfers row",
    )
    expect(
        len(spend2) == len(spend),
        "spending() count is unchanged by the injected transfer",
    )

    print("ok: all_transactions()/spending() tests passed")
