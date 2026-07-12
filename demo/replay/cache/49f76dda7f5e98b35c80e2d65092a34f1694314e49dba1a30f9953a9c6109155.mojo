from vault import *

def main() raises:
    var hits = search("insurance policy number", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var result = ask_local(
            "Use ONLY the text provided. If it clearly contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var r = String(result.strip())
        if r != "none" and r != "":
            print_answer("Your insurance policy number is: " + r)
            return
    # Fallback: scan full text of all files
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for policy number")
        var text = String("")
        if files[i].kind == "pdf":
            text = pdf_text(files[i].alias)
        elif files[i].kind == "md":
            text = md_text(files[i].alias)
        elif files[i].kind == "docx":
            text = docx_text(files[i].alias)
        else:
            continue
        var result = ask_local(
            "Use ONLY the text provided. If it clearly contains an insurance policy number, reply with just the policy number. Otherwise reply exactly 'none'. Do not guess or invent.",
            text
        )
        var r = String(result.strip())
        if r != "none" and r != "":
            print_answer("Your insurance policy number is: " + r)
            return
    print_answer("I couldn't find an insurance policy number in your vault.")