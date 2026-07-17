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
            if x.direction != "debit" or x.state == "":
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
        print_answer("I couldn't find any transactions with a US state on them in your vault.")
        return

    var grand = 0.0
    for s in range(len(totals)):
        grand += totals[s]

    # Find the top state for the narrative
    var top_state = String("")
    var top_amt = 0.0
    for s in range(len(states)):
        if totals[s] > top_amt:
            top_amt = totals[s]
            top_state = states[s]

    result_text("You spent " + money(grand) + " across " + String(len(states))
        + " states. Your top state is " + top_state + " at " + money(top_amt) + ".")

    var gm = geo_map("Spending by state", "state")
    for s in range(len(states)):
        _ = gm.place(states[s], money_val(totals[s]))