from vault import *

def main() raises:
    var hits = search("insurance coverage liability collision comprehensive policy covers", 6)
    var ctx = String("")
    for i in range(len(hits)):
        ctx += String(hits[i].text) + "\n\n"
    var ans = ask_local(
        "Using ONLY the text, state what the auto-insurance policy covers (list the coverage types). "
        "Be concise. If the text does not say, reply that you could not find it.",
        ctx)
    print_answer(String(ans.strip()))
