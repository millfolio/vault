from vault import *

def main() raises:
    var hits = search("insurance policy number", 8)
    for i in range(len(hits)):
        var c = hits[i].copy()
        var answer = ask_local(
            "Use ONLY the text provided. If it contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var s = String(answer.strip())
        if s != "none" and s != "":
            print_answer("Your insurance policy number is: " + s)
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        if files[i].kind == "pdf":
            var text = pdf_text(files[i].alias)
            var answer = ask_local(
                "Use ONLY the text provided. If it contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
                text
            )
            var s = String(answer.strip())
            if s != "none" and s != "":
                print_answer("Your insurance policy number is: " + s)
                return
    print_answer("I couldn't find an insurance policy number in your vault.")