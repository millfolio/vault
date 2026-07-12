from vault import *
def main() raises:
    var hits = search("vehicle registration license plate car", 8)
    var texts = List[String]()
    for i in range(len(hits)):
        texts.append(hits[i].text)
    var answers = ask_local_batch(
        "Reply ONLY with the license plate number or tag visible on the vehicle registration or document, or 'none' if no license plate is present. Use ONLY the text provided. Do not guess or invent.",
        texts)
    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r != "none" and r != "":
            print_answer("Your license plate number is: " + r)
            return
    print_answer("I couldn't find a license plate number in your vault.")