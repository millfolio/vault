from vault import *

def main() raises:
    var files = manifest()
    var cutoff = months_ago(6)

    var merchant_names = List[String]()
    var merchant_counts = List[Int]()
    var merchant_totals = List[Float64]()

    var flat_merchant_idx = List[Int]()
    var flat_week_keys = List[String]()
    var flat_amounts = List[Float64]()

    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        var txns = transactions(files[i].alias)
        for t in range(len(txns)):
            ref x = txns[t]
            if x.direction != "debit":
                continue
            if x.date == "" or x.date < cutoff:
                continue

            var key = x.merchant if x.merchant != "" else x.desc

            var midx = -1
            for m in range(len(merchant_names)):
                if merchant_names[m] == key:
                    midx = m
                    break
            if midx == -1:
                merchant_names.append(key)
                merchant_counts.append(0)
                merchant_totals.append(0.0)
                midx = len(merchant_names) - 1

            merchant_counts[midx] += 1
            merchant_totals[midx] += x.amount

            var parts = x.date.split("-")
            var y = Int(atof(String(parts[0])))
            var mo = Int(atof(String(parts[1])))
            var d = Int(atof(String(parts[2])))

            var a = (14 - mo) // 12
            var yy = y + 4800 - a
            var mm = mo + 12 * a - 3
            var jdn = d + (153 * mm + 2) // 5 + 365 * yy + yy // 4 - yy // 100 + yy // 400 - 32045

            var dow = (jdn + 1) % 7
            var mon_jdn = jdn - dow

            var f = mon_jdn + 32044
            var g = f // 146097
            var dg = f % 146097
            var c2 = (dg // 36524 + 1) * 3 // 4
            var dc = dg - c2 * 36524
            var b = dc // 1461
            var db = dc % 1461
            var c3 = (db // 365 + 1) * 3 // 4
            var dc2 = db - c3 * 365
            var yp = g * 400 + c2 * 100 + b * 4 + c3
            var mp = (dc2 * 5 + 2) // 153
            var dp = dc2 - (153 * mp + 2) // 5 + 1
            var month_out = mp + 3 - 12 * (mp // 10)
            var year_out = yp - 4800 + mp // 10

            var wk = String(year_out) + "-"
            if month_out < 10:
                wk = wk + "0"
            wk = wk + String(month_out) + "-"
            if dp < 10:
                wk = wk + "0"
            wk = wk + String(dp)

            flat_merchant_idx.append(midx)
            flat_week_keys.append(wk)
            flat_amounts.append(x.amount)

    var filtered_midxs = List[Int]()
    for m in range(len(merchant_names)):
        if merchant_counts[m] > 2:
            filtered_midxs.append(m)

    if len(filtered_midxs) == 0:
        print_answer("I couldn't find any merchants with more than 2 transactions in the last 6 months.")
        return

    var all_weeks = List[String]()
    for r in range(len(flat_merchant_idx)):
        var midx = flat_merchant_idx[r]
        var is_filtered = False
        for f2 in range(len(filtered_midxs)):
            if filtered_midxs[f2] == midx:
                is_filtered = True
                break
        if not is_filtered:
            continue
        var wk = flat_week_keys[r]
        var found = False
        for w in range(len(all_weeks)):
            if all_weeks[w] == wk:
                found = True
                break
        if not found:
            all_weeks.append(wk)

    for a in range(len(all_weeks)):
        for b in range(a + 1, len(all_weeks)):
            if all_weeks[b] < all_weeks[a]:
                var tmp = all_weeks[a]
                all_weeks[a] = all_weeks[b]
                all_weeks[b] = tmp

    var headers = List[String]()
    headers.append("Merchant")
    for w in range(len(all_weeks)):
        headers.append("Wk " + all_weeks[w])
    var tbl = table(headers)

    var filtered_totals = List[Float64]()
    for f2 in range(len(filtered_midxs)):
        var midx = filtered_midxs[f2]
        filtered_totals.append(merchant_totals[midx])

    for a in range(len(filtered_midxs)):
        for b in range(a + 1, len(filtered_midxs)):
            if filtered_totals[b] > filtered_totals[a]:
                var tv = filtered_totals[a]
                filtered_totals[a] = filtered_totals[b]
                filtered_totals[b] = tv
                var mv = filtered_midxs[a]
                filtered_midxs[a] = filtered_midxs[b]
                filtered_midxs[b] = mv

    for f2 in range(len(filtered_midxs)):
        var midx = filtered_midxs[f2]
        var week_totals = List[Float64]()
        for w in range(len(all_weeks)):
            week_totals.append(0.0)

        for r in range(len(flat_merchant_idx)):
            if flat_merchant_idx[r] != midx:
                continue
            var wk = flat_week_keys[r]
            for w in range(len(all_weeks)):
                if all_weeks[w] == wk:
                    week_totals[w] += flat_amounts[r]
                    break

        var row_cells = List[Cell]()
        row_cells.append(String(merchant_names[midx]))
        for w in range(len(all_weeks)):
            if week_totals[w] > 0.0:
                row_cells.append(money_val(week_totals[w]))
            else:
                row_cells.append(String("-"))
        _ = tbl.row(row_cells)

    var top_n = len(filtered_midxs)
    if top_n > 10:
        top_n = 10

    for f2 in range(top_n):
        var midx = filtered_midxs[f2]
        var s = series(merchant_names[midx], "time")

        var week_totals2 = List[Float64]()
        for w in range(len(all_weeks)):
            week_totals2.append(0.0)

        for r in range(len(flat_merchant_idx)):
            if flat_merchant_idx[r] != midx:
                continue
            var wk = flat_week_keys[r]
            for w in range(len(all_weeks)):
                if all_weeks[w] == wk:
                    week_totals2[w] += flat_amounts[r]
                    break

        for w in range(len(all_weeks)):
            _ = s.point(all_weeks[w], money_val(week_totals2[w]))

    result_text("Here is your weekly spending per merchant over the last 6 months for merchants with more than 2 transactions. Line graphs are shown for the top " + String(top_n) + " merchants by total spend.")