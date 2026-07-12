from vault import *

def main() raises:
    var hits = search("car insurance policy renewal expiration date auto", 12)
    for i in range(len(hits)):
        ref c = hits[i]
        var d = ask_local(
            "Use ONLY the text provided. If it contains a car insurance renewal date,"
            " expiration date, or policy effective/end date, reply with just that date"
            " in YYYY-MM-DD format or as written. Otherwise reply exactly 'none'."
            " Do not guess or invent.",
            c.text)
        var result = String(d.strip())
        if result != "none" and result != "":
            print_answer("Your car insurance renews on: " + result + ".")
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var text = pdf_text(files[i].alias)
            var d = ask_local(
                "Use ONLY the text provided. If it contains a car insurance renewal date,"
                " expiration date, or policy effective/end date, reply with just that date"
                " in YYYY-MM-DD format or as written. Otherwise reply exactly 'none'."
                " Do not guess or invent.",
                text)
            var result = String(d.strip())
            if result != "none" and result != "":
                print_answer("Your car insurance renews on: " + result + ".")
                return
    print_answer("I couldn't find a car insurance renewal date in your vault.")