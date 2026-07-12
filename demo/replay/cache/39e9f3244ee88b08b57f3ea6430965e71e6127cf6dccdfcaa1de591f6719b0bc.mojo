from vault import *

def main() raises:
    var files = manifest()
    var total_txns = 0
    var total_debits = 0
    var total_credits = 0
    var spent = 0.0
    var received = 0.0

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            total_txns += 1
            if x.direction == "debit":
                total_debits += 1
                spent += x.amount
            elif x.direction == "credit":
                total_credits += 1
                received += x.amount

    if total_txns > 0:
        result_text("You have " + String(total_txns) + " transactions in total: "
            + String(total_debits) + " debits totaling " + money(spent)
            + " and " + String(total_credits) + " credits totaling " + money(received) + ".")
        kpi("Total transactions", count(total_txns))
        kpi("Debits (money out)", money_val(spent))
        kpi("Credits (money in)", money_val(received))
    else:
        print_answer("I couldn't find any verified transactions in your vault.")