from vault import *

def main() raises:
    var hits = search("insurance policy number", 8)
    for i in range(len(hits)):
        var c = hits[i]
        var result = ask_local(
            "Use ONLY the text provided. If it clearly contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var r = String(result.strip())
        if r != "none" and r != "":
            print_answer("Your insurance policy number is: " + r)
            return
    # Fallback: scan full text of both PDFs
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].id + " for policy number")
        var text = pdf_text(files[i].id)
        var result = ask_local(
            "Use ONLY the text provided. If it clearly contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
            text
        )
        var r = String(result.strip())
        if r != "none" and r != "":
            print_answer("Your insurance policy number is: " + r)
            return
    print_answer("I couldn't find an insurance policy number in your vault.")