from vault import *

def main() raises:
    var files = manifest()
    var counts = List[String]()
    var pdf_count = 0
    var csv_count = 0
    var md_count = 0
    var docx_count = 0
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
    var result = String("Your vault contains " + String(len(files)) + " file(s): ")
    var parts = List[String]()
    if pdf_count > 0:
        parts.append(String(pdf_count) + " PDF")
    if csv_count > 0:
        parts.append(String(csv_count) + " CSV")
    if md_count > 0:
        parts.append(String(md_count) + " Markdown")
    if docx_count > 0:
        parts.append(String(docx_count) + " Word (.docx)")
    var summary = String("")
    for i in range(len(parts)):
        if i > 0:
            summary += ", "
        summary += parts[i]
    print_answer(result + summary + ".")