from vault import *

def main() raises:
    var files = manifest()
    var pdf_count = 0
    var csv_count = 0
    var md_count = 0
    var docx_count = 0
    var other_count = 0

    for i in range(len(files)):
        var k = files[i].kind
        if k == "pdf":
            pdf_count += 1
        elif k == "csv":
            csv_count += 1
        elif k == "md":
            md_count += 1
        elif k == "docx":
            docx_count += 1
        else:
            other_count += 1

    var summary = String("Your vault contains " + String(len(files)) + " file(s):\n")
    if pdf_count > 0:
        summary += "  - PDF: " + String(pdf_count) + " file(s)\n"
    if csv_count > 0:
        summary += "  - CSV: " + String(csv_count) + " file(s)\n"
    if md_count > 0:
        summary += "  - Markdown: " + String(md_count) + " file(s)\n"
    if docx_count > 0:
        summary += "  - Word (.docx): " + String(docx_count) + " file(s)\n"
    if other_count > 0:
        summary += "  - Other: " + String(other_count) + " file(s)\n"

    print_answer(summary)