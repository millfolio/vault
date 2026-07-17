from vault import *

def main() raises:
    var hits = search("car insurance renewal expiration date policy", 10)
    var candidates = List[String]()
    var sources = List[String]()
    for i in range(len(hits)):
        candidates.append(hits[i].text)
        sources.append(hits[i].file_alias)

    if len(candidates) == 0:
        # fallback: scan all PDFs directly
        var files = manifest()
        for i in range(len(files)):
            if files[i].kind == "pdf":
                progress("scanning " + files[i].alias)
                var txt = pdf_text(files[i].alias)
                if txt.find("insurance") != -1 or txt.find("Insurance") != -1:
                    var ans = ask_local(
                        "Use ONLY the text provided. Find the car/auto insurance policy renewal or expiration date. "
                        "Reply ONLY with the date in YYYY-MM-DD format if clearly present, or 'none' if not. "
                        "Do not guess or invent.", txt)
                    var r = String(ans.strip())
                    if r != "none" and r != "":
                        print_answer("Your car insurance renews on " + r + ".")
                        return
        print_answer("I couldn't find a car insurance renewal date in your vault.")
        return

    var answers = ask_local_batch(
        "Use ONLY the text provided. If it contains a car or auto insurance policy renewal or expiration date, "
        "reply ONLY with that date in YYYY-MM-DD format (e.g. 2025-06-15). "
        "If no such date is clearly present, reply exactly 'none'. Do not guess or invent.",
        candidates)

    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r != "none" and r != "" and r.find("none") == -1:
            print_answer("Your car insurance renews on " + r + ".")
            return

    # fallback: read full PDF text from files that appeared in search results
    var checked = List[String]()
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind != "pdf":
            continue
        var already = False
        for j in range(len(sources)):
            if sources[j] == files[i].alias:
                already = True
                break
        if not already:
            continue
        var dup = False
        for j in range(len(checked)):
            if checked[j] == files[i].alias:
                dup = True
                break
        if dup:
            continue
        checked.append(files[i].alias)
        progress("deep scan " + files[i].alias)
        var txt = pdf_text(files[i].alias)
        var ans = ask_local(
            "Use ONLY the text provided. Find the car or auto insurance policy renewal or expiration date. "
            "Reply ONLY with the date in YYYY-MM-DD format if clearly present, or 'none' if not. "
            "Do not guess or invent.", txt)
        var r = String(ans.strip())
        if r != "none" and r != "":
            print_answer("Your car insurance renews on " + r + ".")
            return

    print_answer("I couldn't find a car insurance renewal date in your vault.")