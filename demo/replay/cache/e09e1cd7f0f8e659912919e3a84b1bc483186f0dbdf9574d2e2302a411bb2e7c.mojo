from vault import *
def main() raises:
    var hits = search("vehicle registration license plate car", 8)
    for i in range(len(hits)):
        ref c = hits[i]
        var p = ask_local("Use ONLY the text provided. If it clearly contains a license plate number, reply with just the license plate number. Otherwise reply exactly 'none'. Do not guess or invent.", c.text)
        var ps = String(p.strip())
        if ps != "none" and ps != "":
            print_answer("Your license plate number is " + ps + ".")
            return
    # Fallback: scan all chunks of all files
    var files = manifest()
    for i in range(len(files)):
        progress("scanning " + files[i].alias + " for license plate")
        var chunks = file_chunks(files[i].alias)
        var answers = ask_local_batch("Use ONLY the text provided. If it clearly contains a license plate number, reply with just the license plate number. Otherwise reply exactly 'none'. Do not guess or invent.", chunks)
        for j in range(len(answers)):
            var ans = String(answers[j].strip())
            if ans != "none" and ans != "":
                print_answer("Your license plate number is " + ans + ".")
                return
    print_answer("I couldn't find a license plate number in your vault.")