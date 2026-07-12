from vault import *
def main() raises:
    var hits = search("car insurance renewal expiration date policy", 10)
    var candidates = List[String]()
    for i in range(len(hits)):
        candidates.append(hits[i].text)
    var answers = ask_local_batch(
        "Look for a car insurance or auto insurance policy renewal or expiration date."
        " Reply ONLY with the renewal or expiration date in YYYY-MM-DD format, or 'none' if no such date is clearly present."
        " Use ONLY the text provided. Do not guess or invent.",
        candidates)
    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "" and ans != "none.":
            print_answer("Your car insurance renews on " + ans + ".")
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for insurance renewal date")
        if files[i].kind == "pdf":
            var txt = pdf_text(files[i].alias)
            var ans = ask_local(
                "Look for a car insurance or auto insurance policy renewal or expiration date."
                " Reply ONLY with the renewal or expiration date in YYYY-MM-DD format, or 'none' if no such date is clearly present."
                " Use ONLY the text provided. Do not guess or invent.",
                txt)
            var r = String(ans.strip())
            if r != "none" and r != "" and r != "none.":
                print_answer("Your car insurance renews on " + r + ".")
                return
    print_answer("I couldn't find a car insurance renewal date in your vault.")