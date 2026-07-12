from vault import *

def main() raises:
    var files = manifest()
    var total_debit = 0.0
    var total_credit = 0.0
    var n_debit = 0
    var n_credit = 0

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction == "debit":
                total_debit += x.amount
                n_debit += 1
            elif x.direction == "credit":
                total_credit += x.amount
                n_credit += 1

    if n_debit == 0 and n_credit == 0:
        print_answer("I couldn't find any verified transactions in your vault.")
        return

    result_text("You spent " + money(total_debit) + " across " + String(n_debit)
        + " debit transactions, and received " + money(total_credit)
        + " across " + String(n_credit) + " credit transactions.")

    kpi("Total spent (debits)", money_val(total_debit))
    kpi("Total received (credits)", money_val(total_credit))
    kpi("Debit transactions", count(n_debit))
    kpi("Credit transactions", count(n_credit))