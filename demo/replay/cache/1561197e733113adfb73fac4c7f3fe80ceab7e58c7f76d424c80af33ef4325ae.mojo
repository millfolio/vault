from vault import *

def main() raises:
    var hits = search("vehicle registration expiration renewal date", 8)
    for i in range(len(hits)):
        var c = hits[i].copy()
        var d = ask_local(
            "Use ONLY the text provided. If it contains a vehicle registration expiration or renewal date, reply with just that date (e.g. YYYY-MM-DD or MM/DD/YYYY or as written). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text)
        var ds = String(d.strip())
        if ds != "none" and ds != "":
            print_answer("Your vehicle registration expires on: " + ds)
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var text = pdf_text(files[i].alias)
            var d = ask_local(
                "Use ONLY the text provided. If it contains a vehicle registration expiration or renewal date, reply with just that date (e.g. YYYY-MM-DD or MM/DD/YYYY or as written). Otherwise reply exactly 'none'. Do not guess or invent.",
                text)
            var ds = String(d.strip())
            if ds != "none" and ds != "":
                print_answer("Your vehicle registration expires on: " + ds)
                return
    print_answer("I couldn't find a vehicle registration expiration date in your vault.")