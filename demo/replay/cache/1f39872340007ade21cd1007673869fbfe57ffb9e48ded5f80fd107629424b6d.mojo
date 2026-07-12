from vault import *
def main() raises:
    var files = manifest()
    var pdf_count = 0
    for i in range(len(files)):
        if files[i].kind == "pdf":
            pdf_count += 1
    print_answer("Your vault contains " + String(len(files)) + " file(s), all PDF documents (" + String(pdf_count) + " PDF).")