from vault import *

def main() raises:
    var hits = search("insurance policy number", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var ans = ask_local(
            "Use ONLY the text provided. If it contains an insurance policy number,"
            " reply with just the policy number. Otherwise reply exactly 'none'."
            " Do not guess or invent.",
            c.text)
        var s = String(ans.strip())
        if s != "none" and s != "":
            print_answer("Your insurance policy number is: " + s)
            return
    # fallback: scan all PDFs fully
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var text = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If it contains an insurance policy number,"
                " reply with just the policy number. Otherwise reply exactly 'none'."
                " Do not guess or invent.",
                text)
            var s = String(ans.strip())
            if s != "none" and s != "":
                print_answer("Your insurance policy number is: " + s)
                return
    print_answer("I couldn't find an insurance policy number in your vault.")