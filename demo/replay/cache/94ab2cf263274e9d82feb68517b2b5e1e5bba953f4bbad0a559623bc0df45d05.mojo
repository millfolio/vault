from vault import *

def main() raises:
    var hits = search("car vehicle make model year registration insurance", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var answer = ask_local(
            "Use ONLY the text provided. If it clearly mentions the make, model, or year of a car or vehicle, reply with just that information (e.g. '2019 Toyota Camry'). Otherwise reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var s = String(answer.strip())
        if s != "none" and s != "":
            print_answer("Your car is a " + s + ".")
            return
    # fallback: scan full text of each file
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for vehicle info")
        var text = String("")
        if files[i].kind == "pdf":
            text = pdf_text(files[i].alias)
        elif files[i].kind == "md":
            text = md_text(files[i].alias)
        elif files[i].kind == "docx":
            text = docx_text(files[i].alias)
        else:
            continue
        var answer = ask_local(
            "Use ONLY the text provided. If it clearly mentions the make, model, or year of a car or vehicle, reply with just that information (e.g. '2019 Toyota Camry'). Otherwise reply exactly 'none'. Do not guess or invent.",
            text
        )
        var s = String(answer.strip())
        if s != "none" and s != "":
            print_answer("Your car is a " + s + ".")
            return
    print_answer("I couldn't find information about your car in your vault.")