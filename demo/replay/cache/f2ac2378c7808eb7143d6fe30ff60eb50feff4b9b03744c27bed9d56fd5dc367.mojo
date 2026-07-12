from vault import *
def main() raises:
    var hits = search("insurance policy number", 8)
    var texts = List[String]()
    for i in range(len(hits)):
        texts.append(hits[i].text)
    var answers = ask_local_batch(
        "Use ONLY the text provided. If it contains an insurance policy number, reply with ONLY that policy number. If not, reply exactly 'none'. Do not guess or invent.",
        texts)
    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "":
            print_answer("Your insurance policy number is: " + ans)
            return
    # Fallback: scan all PDF files directly
    var files = manifest()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias)
            var chunks = file_chunks(files[i].alias)
            var cands = List[String]()
            for c in range(len(chunks)):
                cands.append(chunks[c])
            var batch = ask_local_batch(
                "Use ONLY the text provided. If it contains an insurance policy number, reply with ONLY that policy number. If not, reply exactly 'none'. Do not guess or invent.",
                cands)
            for b in range(len(batch)):
                var r = String(batch[b].strip())
                if r != "none" and r != "":
                    print_answer("Your insurance policy number is: " + r)
                    return
    print_answer("I couldn't find an insurance policy number in your vault.")