from vault import *

def main() raises:
    var files = manifest()
    var spent = 0.0
    var received = 0.0
    var n_debit = 0
    var n_credit = 0
    var lo = String("")
    var hi = String("")

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.date != "":
                if lo == "" or x.date < lo:
                    lo = x.date
                if hi == "" or x.date > hi:
                    hi = x.date
            if x.direction == "debit":
                # exclude transfers (account-to-account moves are not spending)
                var is_transfer = False
                for g in range(len(x.tags)):
                    if x.tags[g] == "transfers":
                        is_transfer = True
                        break
                if not is_transfer:
                    spent += x.amount
                    n_debit += 1
            elif x.direction == "credit":
                var is_transfer = False
                for g in range(len(x.tags)):
                    if x.tags[g] == "transfers":
                        is_transfer = True
                        break
                if not is_transfer:
                    received += x.amount
                    n_credit += 1

    if n_debit == 0 and n_credit == 0:
        print_answer("I couldn't find any verified transactions in your vault.")
        return

    var date_range = ""
    if lo != "" and hi != "":
        date_range = " (from " + lo + " to " + hi + ")"

    result_text("You spent " + money(spent) + " across " + String(n_debit)
        + " purchases" + date_range + ". You also received "
        + money(received) + " across " + String(n_credit) + " credits/deposits.")

    kpi("Total spent", money_val(spent))
    kpi("Total received", money_val(received))
    kpi("Purchase transactions", count(n_debit))

    # Per-month spending breakdown
    var months = List[String]()
    var month_totals = List[Float64]()

    for i in range(len(files)):
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit" or x.date == "":
                continue
            var is_transfer = False
            for g in range(len(x.tags)):
                if x.tags[g] == "transfers":
                    is_transfer = True
                    break
            if is_transfer:
                continue
            var p = x.date.split("-")
            if len(p) < 2:
                continue
            var mk = String(p[0]) + "-" + String(p[1])
            var found = False
            for m in range(len(months)):
                if months[m] == mk:
                    month_totals[m] += x.amount
                    found = True
                    break
            if not found:
                months.append(mk)
                month_totals.append(x.amount)

    if len(months) > 1:
        # sort months ascending (ISO strings compare correctly)
        for a in range(len(months)):
            var best = a
            for b in range(a + 1, len(months)):
                if months[b] < months[best]:
                    best = b
            if best != a:
                var tv = month_totals[a]
                month_totals[a] = month_totals[best]
                month_totals[best] = tv
                var nv = months[a]
                months[a] = months[best]
                months[best] = nv
        var s = series("Spending by month", "time")
        for m in range(len(months)):
            _ = s.point(months[m] + "-01", money_val(month_totals[m]))