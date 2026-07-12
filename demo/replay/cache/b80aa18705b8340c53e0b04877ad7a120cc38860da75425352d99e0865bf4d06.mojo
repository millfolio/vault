from vault import *

def main() raises:
    var hits = search("car insurance renewal expiration policy date", 10)
    for i in range(len(hits)):
        var c = hits[i]
        var d = ask_local(
            "Use ONLY the text provided. If it contains a car insurance renewal or expiration date, reply with just that date in YYYY-MM-DD format or a clear description of the date (e.g. 'March 15, 2025'). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text)
        var ans = String(d.strip())
        if ans != "none" and ans != "":
            print_answer("Your car insurance renews on: " + ans)
            return
    # fallback: scan both PDFs fully
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].id + " for insurance renewal date")
            var text = pdf_text(files[i].id)
            var d = ask_local(
                "Use ONLY the text provided. If it contains a car insurance renewal or expiration date, reply with just that date in YYYY-MM-DD format or as a clear human-readable date (e.g. 'March 15, 2025'). Otherwise reply exactly 'none'. Do not guess or invent.",
                text)
            var ans = String(d.strip())
            if ans != "none" and ans != "":
                print_answer("Your car insurance renews on: " + ans)
                return
    print_answer("I couldn't find a car insurance renewal date in your vault.")