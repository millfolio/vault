from vault import *
def main() raises:
    var hits = search("car vehicle make model year registration insurance", 8)
    var texts = List[String]()
    for i in range(len(hits)):
        texts.append(hits[i].text)
    var answers = ask_local_batch(
        "Use ONLY the text provided. If it mentions a car, vehicle make, model, or year, reply with just that information (e.g. '2019 Honda Civic'). Otherwise reply exactly 'none'. Do not guess or invent.",
        texts)
    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r != "none" and r != "":
            print_answer("Your car is a " + r + ".")
            return
    print_answer("I couldn't find any information about your car in your vault.")