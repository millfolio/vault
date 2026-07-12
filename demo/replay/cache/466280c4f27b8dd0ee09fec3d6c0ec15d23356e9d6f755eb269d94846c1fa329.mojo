from vault import *

def main() raises:
    var total = 0
    var files = manifest()
    for i in range(len(files)):
        progress("checking " + files[i].alias)
        var txns = transactions(files[i].alias)
        total += len(txns)
    if total > 0:
        print_answer("You have " + String(total) + " transactions across all your files.")
    else:
        print_answer("I couldn't find any verified transactions in your vault.")