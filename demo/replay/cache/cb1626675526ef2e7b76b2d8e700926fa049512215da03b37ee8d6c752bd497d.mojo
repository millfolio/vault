from vault import *
def main() raises:
    var hits = search("car insurance renewal expiration date policy", 10)
    var candidates = List[String]()
    var sources = List[String]()
    for i in range(len(hits)):
        candidates.append(hits[i].text)
        sources.append(hits[i].file_alias)
    var answers = ask_local_batch(
        "Use ONLY the text provided. If it contains a car insurance renewal or expiration date, reply with ONLY that date in YYYY-MM-DD format or as written. If it does not clearly contain a car insurance renewal date, reply exactly 'none'. Do not guess or invent.",
        candidates)
    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r != "none" and r != "" and r != "None":
            print_answer("Your car insurance renews on " + r + ".")
            return
    # Fallback: scan all PDFs directly
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var txt = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If it contains a car insurance renewal or expiration date, reply with ONLY that date. If not clearly present, reply exactly 'none'. Do not guess or invent.",
                txt)
            var r = String(ans.strip())
            if r != "none" and r != "" and r != "None":
                print_answer("Your car insurance renews on " + r + ".")
                return
    print_answer("I couldn't find a car insurance renewal date in your vault.")