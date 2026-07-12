from vault import *
def main() raises:
    var hits = search("vehicle registration license plate car plate number", 8)
    for c in hits:
        var p = ask_local("Reply ONLY with the license plate number or code, or 'none'. Use ONLY the text provided. If it does not clearly contain a license plate, reply exactly 'none'. Do not guess or invent.", c.text)
        if String(p.strip()) != "none" and String(p.strip()) != "":
            print_answer("Your license plate number is " + String(p.strip()) + ".")
            return
    print_answer("I couldn't find a license plate number in your vault.")