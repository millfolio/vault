from vault import *

def main() raises:
    var hits = search("car insurance policy renewal expiration date auto", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var d = ask_local(
            "Use ONLY the text provided. If it contains a car insurance renewal date,"
            " expiration date, or policy effective/end date, reply with just that date"
            " in YYYY-MM-DD format. If the year is not clear, use the most likely year"
            " from context. If the text does not clearly contain such a date, reply"
            " exactly 'none'. Do not guess or invent.",
            c.text)
        var result = String(d.strip())
        if result != "none" and result != "":
            print_answer("Your car insurance renews on " + result + ".")
            return
    # fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for insurance renewal date")
        if files[i].kind == "pdf":
            var text = pdf_text(files[i].alias)
            var d = ask_local(
                "Use ONLY the text provided. If it contains a car insurance renewal date,"
                " expiration date, or policy effective/end date, reply with just that date"
                " in YYYY-MM-DD format. If the year is not clear, use the most likely year"
                " from context. If the text does not clearly contain such a date, reply"
                " exactly 'none'. Do not guess or invent.",
                text)
            var result = String(d.strip())
            if result != "none" and result != "":
                print_answer("Your car insurance renews on " + result + ".")
                return
    print_answer("I couldn't find a car insurance renewal date in your vault.")