from vault import *
def main() raises:
    var hits = search("vehicle registration expiration date renewal", 8)
    for i in range(len(hits)):
        var c = hits[i]
        var d = ask_local(
            "Use ONLY the text provided. If it clearly states a vehicle registration"
            " expiration or renewal date, reply with just that date (e.g. YYYY-MM-DD"
            " or MM/DD/YYYY or as written). Otherwise reply exactly 'none'."
            " Do not guess or invent.",
            c.text)
        var ans = String(d.strip())
        if ans != "none" and ans != "":
            print_answer("Your vehicle registration expires on " + ans + ".")
            return
    # fallback: scan all chunks of both PDFs
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].id + " for registration expiration")
        if files[i].kind == "pdf":
            var text = pdf_text(files[i].id)
            var result = ask_local(
                "Use ONLY the text provided. If it clearly states a vehicle registration"
                " expiration or renewal date, reply with just that date. Otherwise reply"
                " exactly 'none'. Do not guess or invent.",
                text)
            var ans2 = String(result.strip())
            if ans2 != "none" and ans2 != "":
                print_answer("Your vehicle registration expires on " + ans2 + ".")
                return
    print_answer("I couldn't find a vehicle registration expiration date in your vault.")