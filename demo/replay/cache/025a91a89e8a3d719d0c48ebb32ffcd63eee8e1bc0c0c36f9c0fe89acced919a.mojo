from vault import *
def main() raises:
    var hits = search("license plate vehicle registration car", 8)
    var items = List[String]()
    for i in range(len(hits)):
        items.append(hits[i].text)
    var answers = ask_local_batch(
        "Reply ONLY with the license plate number found in the text, or 'none' if no license plate is present. Use ONLY the text provided. Do not guess or invent.",
        items)
    for i in range(len(answers)):
        var a = String(answers[i].strip())
        if a != "none" and a != "":
            print_answer("Your license plate number is " + a + ".")
            return
    print_answer("I couldn't find a license plate number in your vault.")