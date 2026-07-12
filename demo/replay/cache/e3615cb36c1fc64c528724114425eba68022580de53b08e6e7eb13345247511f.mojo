from vault import *

def main() raises:
    var hits = search("car insurance renewal expiration policy date auto", 10)
    var candidates = List[String]()
    var sources = List[String]()
    for i in range(len(hits)):
        candidates.append(hits[i].text)
        sources.append(hits[i].file_alias)

    if len(candidates) == 0:
        # Fallback: scan all PDFs directly
        var files = manifest()
        for i in range(len(files)):
            if files[i].kind == "pdf":
                var txt = pdf_text(files[i].alias)
                candidates.append(txt)
                sources.append(files[i].alias)

    if len(candidates) == 0:
        print_answer("I couldn't find any car insurance documents in your vault.")
        return

    var answers = ask_local_batch(
        "Use ONLY the text provided. If this text contains a car insurance policy renewal or expiration date, reply with ONLY that date in the format YYYY-MM-DD. If the date is not in YYYY-MM-DD format, convert it. If the text does not clearly contain a car insurance renewal or expiration date, reply exactly 'none'. Do not guess or invent.",
        candidates
    )

    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "" and ans.find("none") == -1:
            print_answer("Your car insurance renews on " + ans + ".")
            return

    # Fallback: try reading each PDF fully
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("reading " + files[i].alias)
            var txt = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If this text contains a car insurance policy renewal or expiration date, reply with ONLY that date in the format YYYY-MM-DD. If the date is not in YYYY-MM-DD format, convert it. If the text does not clearly contain a car insurance renewal or expiration date, reply exactly 'none'. Do not guess or invent.",
                txt
            )
            var a = String(ans.strip())
            if a != "none" and a != "":
                print_answer("Your car insurance renews on " + a + ".")
                return

    print_answer("I couldn't find a car insurance renewal date in your vault.")