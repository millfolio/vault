from vault import *

def main() raises:
    var hits = search("car vehicle make model year registration", 10)
    var texts = List[String]()
    for i in range(len(hits)):
        texts.append(hits[i].text)
    var answers = ask_local_batch(
        "Use ONLY the text provided. If it mentions a car, vehicle, or automobile with a make, model, or year, reply with just those details (e.g. '2019 Toyota Camry'). Otherwise reply 'none'. Do not guess or invent.",
        texts)
    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r != "none" and r != "":
            print_answer("Your car is a " + r + ".")
            return
    # Fallback: scan all PDFs fully
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var txt = pdf_text(files[i].alias)
            if txt == "":
                continue
            var ans = ask_local(
                "Use ONLY the text provided. If it mentions a car, vehicle, or automobile with a make, model, or year, reply with just those details (e.g. '2019 Toyota Camry'). Otherwise reply 'none'. Do not guess or invent.",
                txt)
            var r = String(ans.strip())
            if r != "none" and r != "":
                print_answer("Your car is a " + r + ".")
                return
    print_answer("I couldn't find any car or vehicle details in your vault.")