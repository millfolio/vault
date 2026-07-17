from vault import *
def main() raises:
    var hits = search("vehicle registration license plate car tag", 8)
    var items = List[String]()
    for i in range(len(hits)):
        items.append(hits[i].text)
    var answers = ask_local_batch(
        "Reply ONLY with the license plate number or tag (e.g. 'ABC1234'), or 'none' if the text does not clearly contain a license plate. Use ONLY the text provided. Do not guess or invent.",
        items)
    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "":
            print_answer("Your license plate number is: " + ans)
            return
    print_answer("I couldn't find a license plate number in your vault.")