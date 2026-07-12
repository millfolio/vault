from vault import *
def main() raises:
    var hits = search("vehicle registration expiration renewal date", 8)
    var texts = List[String]()
    for i in range(len(hits)):
        texts.append(hits[i].text)
    var answers = ask_local_batch(
        "Use ONLY the text provided. If it contains a vehicle registration expiration or renewal date, reply with ONLY that date in YYYY-MM-DD format. If the year is not present, do your best to infer it from context. If the text does not clearly contain a registration expiration or renewal date, reply exactly 'none'. Do not guess or invent.",
        texts)
    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "":
            print_answer("Your vehicle registration expires on " + ans + ".")
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " (" + String(i+1) + "/" + String(len(files)) + ")")
        if files[i].kind == "pdf":
            var chunks = file_chunks(files[i].alias)
            var cands = List[String]()
            for c in range(len(chunks)):
                var txt = chunks[c]
                if txt.find("registr") != -1 or txt.find("Registr") != -1 or txt.find("expir") != -1 or txt.find("Expir") != -1 or txt.find("renewal") != -1 or txt.find("Renewal") != -1:
                    cands.append(txt)
            if len(cands) == 0:
                continue
            var batch_ans = ask_local_batch(
                "Use ONLY the text provided. If it contains a vehicle registration expiration or renewal date, reply with ONLY that date in YYYY-MM-DD format. If the year is not present, do your best to infer it from context. If the text does not clearly contain a registration expiration or renewal date, reply exactly 'none'. Do not guess or invent.",
                cands)
            for a in range(len(batch_ans)):
                var r = String(batch_ans[a].strip())
                if r != "none" and r != "":
                    print_answer("Your vehicle registration expires on " + r + ".")
                    return
    print_answer("I couldn't find a vehicle registration expiration date in your vault.")