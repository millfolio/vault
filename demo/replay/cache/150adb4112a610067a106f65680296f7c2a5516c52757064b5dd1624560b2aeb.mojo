from vault import *

def main() raises:
    var hits = search("vehicle registration expiration renewal date DMV", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var ans = ask_local(
            "Use ONLY the text provided. If it clearly contains a vehicle registration expiration or renewal date, reply with just that date (e.g. YYYY-MM-DD or MM/DD/YYYY or as written). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text)
        var s = String(ans.strip())
        if s != "none" and s != "":
            print_answer("Your vehicle registration expires on: " + s)
            return
    # Fallback: scan all PDF files fully
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var text = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If it clearly contains a vehicle registration expiration or renewal date, reply with just that date (e.g. YYYY-MM-DD or MM/DD/YYYY or as written). Otherwise reply exactly 'none'. Do not guess or invent.",
                text)
            var s = String(ans.strip())
            if s != "none" and s != "":
                print_answer("Your vehicle registration expires on: " + s)
                return
    print_answer("I couldn't find a vehicle registration expiration date in your vault.")