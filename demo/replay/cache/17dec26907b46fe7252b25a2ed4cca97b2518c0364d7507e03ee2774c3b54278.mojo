from vault import *

def main() raises:
    var files = manifest()
    var total_debit = 0.0
    var total_credit = 0.0
    var n_debit = 0
    var n_credit = 0
    var any_txns = False

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            any_txns = True
            if x.direction == "debit":
                total_debit += x.amount
                n_debit += 1
            elif x.direction == "credit":
                total_credit += x.amount
                n_credit += 1

    if any_txns:
        result_text("You spent " + money(total_debit) + " across " + String(n_debit)
            + " debit transactions, and received " + money(total_credit)
            + " across " + String(n_credit) + " credit transactions.")
        kpi("Total spent (debits)", money_val(total_debit))
        kpi("Total received (credits)", money_val(total_credit))
        kpi("Debit transactions", count(n_debit))
        kpi("Credit transactions", count(n_credit))
    else:
        # Fallback: try CSV rows
        var csv_total = 0.0
        var csv_n = 0
        var found_csv = False
        for i in range(len(files)):
            if files[i].kind == "csv":
                var rows = csv_rows(files[i].alias)
                if len(rows) > 0:
                    found_csv = True
                    var amounts = List[String]()
                    for r in range(len(rows)):
                        var row_text = String("")
                        for c in range(4):
                            row_text += rows[r][c] + " "
                        amounts.append(row_text)
                    var answers = ask_local_batch(
                        "Use ONLY the text provided. If this row contains a spending/expense amount,"
                        " reply with ONLY the numeric amount (e.g. 42.10). Otherwise reply 'none'."
                        " Do not guess or invent.", amounts)
                    for a in range(len(answers)):
                        var s = String(answers[a].strip())
                        if s != "none" and s != "":
                            var amt = parse_amount(s)
                            if amt > 0.0:
                                csv_total += amt
                                csv_n += 1
        if found_csv and csv_n > 0:
            result_text("You spent approximately " + money(csv_total) + " across "
                + String(csv_n) + " expense entries in your records.")
            kpi("Total spent", money_val(csv_total))
            kpi("Expense entries", count(csv_n))
        else:
            print_answer("I couldn't find any verified spending transactions in your vault.")