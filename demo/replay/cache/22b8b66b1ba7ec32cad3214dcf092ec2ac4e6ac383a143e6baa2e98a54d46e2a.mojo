from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    var merchants = List[String]()
    var months_list = List[String]()
    var amounts = List[Float64]()

    var merch_names = List[String]()
    var merch_totals = List[Float64]()
    var merch_counts = List[Int]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.date == "" or x.date < cutoff:
                continue
            var key_merch = x.merchant if x.merchant != "" else x.desc
            var p = x.date.split("-")
            if len(p) < 2:
                continue
            var mk = String(p[0]) + "-" + String(p[1])

            var found_cell = False
            for c in range(len(merchants)):
                if merchants[c] == key_merch and months_list[c] == mk:
                    amounts[c] += x.amount
                    found_cell = True
                    break
            if not found_cell:
                merchants.append(key_merch)
                months_list.append(mk)
                amounts.append(x.amount)

            var found_m = False
            for m in range(len(merch_names)):
                if merch_names[m] == key_merch:
                    merch_totals[m] += x.amount
                    merch_counts[m] += 1
                    found_m = True
                    break
            if not found_m:
                merch_names.append(key_merch)
                merch_totals.append(x.amount)
                merch_counts.append(1)

    var qualified = List[String]()
    for m in range(len(merch_names)):
        if merch_counts[m] > 2:
            qualified.append(merch_names[m])

    if len(qualified) == 0:
        print_answer("No merchants had more than 2 transactions in the last 6 months.")
        return

    var unique_months = List[String]()
    for c in range(len(months_list)):
        var mk = months_list[c]
        var found = False
        for u in range(len(unique_months)):
            if unique_months[u] == mk:
                found = True
                break
        if not found:
            unique_months.append(mk)

    for a in range(len(unique_months)):
        for b in range(a + 1, len(unique_months)):
            if unique_months[b] < unique_months[a]:
                var tmp = unique_months[a]
                unique_months[a] = unique_months[b]
                unique_months[b] = tmp

    var headers = List[String]()
    headers.append("Merchant")
    for u in range(len(unique_months)):
        headers.append(unique_months[u])
    headers.append("Total")

    var tbl = table(headers)

    for q in range(len(qualified)):
        var merch = qualified[q]
        var merch_total = 0.0
        var cell_amts = List[Float64]()
        for u in range(len(unique_months)):
            var mk = unique_months[u]
            var cell_amt = 0.0
            for c in range(len(merchants)):
                if merchants[c] == merch and months_list[c] == mk:
                    cell_amt += amounts[c]
                    break
            merch_total += cell_amt
            cell_amts.append(cell_amt)
        var row_cells = List[Cell]()
        row_cells.append(merch)
        for u in range(len(unique_months)):
            if cell_amts[u] > 0.0:
                row_cells.append(money_val(cell_amts[u]))
            else:
                row_cells.append("-")
        row_cells.append(money_val(merch_total))
        _ = tbl.row(row_cells)

    var q_totals = List[Float64]()
    for q in range(len(qualified)):
        var merch = qualified[q]
        for m in range(len(merch_names)):
            if merch_names[m] == merch:
                q_totals.append(merch_totals[m])
                break

    for a in range(len(qualified)):
        var best = a
        for b in range(a + 1, len(qualified)):
            if q_totals[b] > q_totals[best]:
                best = b
        if best != a:
            var tv = q_totals[a]
            q_totals[a] = q_totals[best]
            q_totals[best] = tv
            var nv = qualified[a]
            qualified[a] = qualified[best]
            qualified[best] = nv

    var top_n = len(qualified)
    if top_n > 10:
        top_n = 10

    for q in range(top_n):
        var merch = qualified[q]
        var s = series(merch + " - monthly spending", "time")
        for u in range(len(unique_months)):
            var mk = unique_months[u]
            var cell_amt = 0.0
            for c in range(len(merchants)):
                if merchants[c] == merch and months_list[c] == mk:
                    cell_amt += amounts[c]
                    break
            _ = s.point(mk + "-01", money_val(cell_amt))

    result_text("Here is your monthly spending per merchant (last 6 months, merchants with more than 2 transactions). Line graphs show the top " + String(top_n) + " merchants by total spend.")