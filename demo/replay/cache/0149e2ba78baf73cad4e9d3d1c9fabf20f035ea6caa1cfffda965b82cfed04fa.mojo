from vault import *

def main() raises:
    var hits = search("vehicle registration license plate car auto", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var p = ask_local("Use ONLY the text provided. If it contains a license plate number, reply with just the license plate number. Otherwise reply exactly 'none'. Do not guess or invent.", c.text)
        var ps = String(p.strip())
        if ps != "none" and ps != "":
            print_answer("Your license plate number is: " + ps)
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning file " + String(i + 1) + "/" + String(len(files)))
        if files[i].kind == "pdf":
            var text = pdf_text(files[i].alias)
            var p = ask_local("Use ONLY the text provided. If it contains a license plate number or vehicle plate number, reply with just the license plate number. Otherwise reply exactly 'none'. Do not guess or invent.", text)
            var ps = String(p.strip())
            if ps != "none" and ps != "":
                print_answer("Your license plate number is: " + ps)
                return
    print_answer("I couldn't find a license plate number in your vault.")