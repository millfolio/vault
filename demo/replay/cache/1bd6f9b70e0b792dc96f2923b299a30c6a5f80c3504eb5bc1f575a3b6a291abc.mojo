from vault import *

def main() raises:
    var files = manifest()
    var states = List[String]()
    var totals = List[Float64]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.country != "USA" or x.state == "":
                continue
            var found = False
            for s in range(len(states)):
                if states[s] == x.state:
                    totals[s] += x.amount
                    found = True
                    break
            if not found:
                states.append(x.state)
                totals.append(x.amount)

    if len(states) == 0:
        print_answer("I couldn't find any US state-located spending transactions in your vault.")
        return

    var grand = 0.0
    var top_state = String("")
    var top_total = 0.0
    for s in range(len(states)):
        grand += totals[s]
        if totals[s] > top_total:
            top_total = totals[s]
            top_state = states[s]

    result_text("Your total US state-located spending is " + money(grand) + " across "
        + String(len(states)) + " states. Your top state is " + top_state
        + " at " + money(top_total) + ".")

    var gm = geo_map("Spending by US state", "state")
    for s in range(len(states)):
        _ = gm.place(states[s], money_val(totals[s]))