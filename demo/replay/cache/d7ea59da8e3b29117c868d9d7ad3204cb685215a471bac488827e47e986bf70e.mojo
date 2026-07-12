from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    var merchants = List[String]()
    var months_list = List[String]()

    var flat_merch = List[Int]()
    var flat_month_str = List[String]()
    var flat_amt = List[Float64]()
    var merch_txn_count = List[Int]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit" or x.date == "" or x.date < cutoff:
                continue
            var key = x.merchant if x.merchant != "" else x.desc
            var p = x.date.split("-")
            if len(p) < 2:
                continue
            var mk = String(p[0]) + "-" + String(p[1])

            var mi = -1
            for m in range(len(merchants)):
                if merchants[m] == key:
                    mi = m
                    break
            if mi == -1:
                mi = len(merchants)
                merchants.append(key)
                merch_txn_count.append(0)
            merch_txn_count[mi] += 1

            var found_mo = False
            for mo in range(len(months_list)):
                if months_list[mo] == mk:
                    found_mo = True
                    break
            if not found_mo:
                months_list.append(mk)

            flat_merch.append(mi)
            flat_month_str.append(mk)
            flat_amt.append(x.amount)

    # Sort months_list ascending
    var nm = len(months_list)
    for a in range(nm):
        for b in range(a+1, nm):
            if months_list[b] < months_list[a]:
                var tmp = months_list[a]
                months_list[a] = months_list[b]
                months_list[b] = tmp

    # Build merchant totals
    var merch_total = List[Float64]()
    for m in range(len(merchants)):
        merch_total.append(0.0)
    for f in range(len(flat_merch)):
        merch_total[flat_merch[f]] += flat_amt[f]

    # Filter merchants with more than 2 transactions
    var filtered_merch_idx = List[Int]()
    for m in range(len(merchants)):
        if merch_txn_count[m] > 2:
            filtered_merch_idx.append(m)

    if len(filtered_merch_idx) == 0:
        print_answer("No merchants had more than 2 transactions in the last 6 months.")
        return

    # Sort filtered merchants by total descending
    for a in range(len(filtered_merch_idx)):
        for b in range(a+1, len(filtered_merch_idx)):
            if merch_total[filtered_merch_idx[b]] > merch_total[filtered_merch_idx[a]]:
                var tmp = filtered_merch_idx[a]
                filtered_merch_idx[a] = filtered_merch_idx[b]
                filtered_merch_idx[b] = tmp

    var nfm = len(filtered_merch_idx)

    # Build matrix as flat list: matrix_flat[i * nm + j] = amount
    var matrix_flat = List[Float64]()
    for i in range(nfm * nm):
        matrix_flat.append(0.0)

    for f in range(len(flat_merch)):
        var mi = flat_merch[f]
        var pos = -1
        for p in range(nfm):
            if filtered_merch_idx[p] == mi:
                pos = p
                break
        if pos == -1:
            continue
        var mo_key = flat_month_str[f]
        var moi_sorted = 0
        for j in range(nm):
            if months_list[j] == mo_key:
                moi_sorted = j
                break
        matrix_flat[pos * nm + moi_sorted] += flat_amt[f]

    result_text("Here is the monthly spending breakdown by merchant (last 6 months, merchants with >2 transactions).")

    # Build table headers
    var headers = List[String]()
    headers.append("Merchant")
    for j in range(nm):
        headers.append(months_list[j])
    headers.append("Total")

    var final_tbl = table(headers)
    for i in range(nfm):
        var mi = filtered_merch_idx[i]
        var display_row = List[Cell]()
        display_row.append(Cell(merchants[mi]))
        for j in range(nm):
            var amt = matrix_flat[i * nm + j]
            if amt > 0.0:
                display_row.append(money_val(amt))
            else:
                display_row.append(Cell("-"))
        display_row.append(money_val(merch_total[mi]))
        _ = final_tbl.row(display_row)

    # Emit line graphs for top 10 merchants
    var top10 = nfm
    if top10 > 10:
        top10 = 10

    for i in range(top10):
        var mi = filtered_merch_idx[i]
        var s = series(merchants[mi], "time")
        for j in range(nm):
            var amt = matrix_flat[i * nm + j]
            if amt > 0.0:
                _ = s.point(months_list[j] + "-01", money_val(amt))