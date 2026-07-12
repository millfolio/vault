from vault import *

def main() raises:
    var hits = search("vehicle car registration make model year license", 10)
    for i in range(len(hits)):
        ref c = hits[i]
        var ans = ask_local(
            "Use ONLY the text provided. If it mentions the make, model, or year of a car or vehicle, reply with just those details (e.g. '2019 Honda Civic'). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text)
        var s = String(ans.strip())
        if s != "none" and s != "":
            print_answer("Your car is a " + s + ".")
            return
    # fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for vehicle info")
        if files[i].kind == "pdf":
            var text = pdf_text(files[i].alias)
            var ans = ask_local(
                "Use ONLY the text provided. If it mentions the make, model, or year of a car or vehicle, reply with just those details (e.g. '2019 Honda Civic'). Otherwise reply exactly 'none'. Do not guess or invent.",
                text)
            var s = String(ans.strip())
            if s != "none" and s != "":
                print_answer("Your car is a " + s + ".")
                return
    print_answer("I couldn't find any car or vehicle information in your vault.")