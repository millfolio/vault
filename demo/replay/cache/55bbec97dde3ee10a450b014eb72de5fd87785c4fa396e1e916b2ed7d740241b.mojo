from vault import *

def main() raises:
    var files = manifest()
    var total_txns = 0
    var debit_count = 0
    var credit_count = 0
    var debit_total = 0.0
    var credit_total = 0.0

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            total_txns += 1
            if x.direction == "debit":
                debit_count += 1
                debit_total += x.amount
            elif x.direction == "credit":
                credit_count += 1
                credit_total += x.amount

    if total_txns > 0:
        result_text("You have " + String(total_txns) + " transactions total: "
            + String(debit_count) + " debits totaling " + money(debit_total)
            + " and " + String(credit_count) + " credits totaling " + money(credit_total) + ".")
        kpi("Total transactions", count(total_txns))
        kpi("Debits", count(debit_count))
        kpi("Total spent (debits)", money_val(debit_total))
        kpi("Credits", count(credit_count))
        kpi("Total received (credits)", money_val(credit_total))
    else:
        print_answer("I couldn't find any verified transactions in your vault.")