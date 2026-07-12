from vault import *

def main() raises:
    var hits = search("car vehicle make model registration title", 8)
    for i in range(len(hits)):
        progress("checking result " + String(i + 1) + "/" + String(len(hits)))
        var c = hits[i].copy()
        var ans = ask_local(
            "Use ONLY the text provided. If it mentions a car or vehicle, reply with the make, model, and year (e.g. '2019 Toyota Camry'). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text)
        var s = String(ans.strip())
        if s != "none" and s != "":
            print_answer("Your car is a " + s + ".")
            return
    # fallback: scan all pdf files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias)
        if files[i].kind == "pdf":
            var txt = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If it mentions a car or vehicle, reply with the make, model, and year (e.g. '2019 Toyota Camry'). Otherwise reply exactly 'none'. Do not guess or invent.",
                txt)
            var s = String(ans.strip())
            if s != "none" and s != "":
                print_answer("Your car is a " + s + ".")
                return
    print_answer("I couldn't find any car or vehicle information in your vault.")