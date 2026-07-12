from vault import *
def main() raises:
    var files = manifest()
    var n_pdf = 0
    var n_csv = 0
    var n_md = 0
    var n_docx = 0
    for i in range(len(files)):
        var k = files[i].kind
        if k == "pdf":
            n_pdf += 1
        elif k == "csv":
            n_csv += 1
        elif k == "md":
            n_md += 1
        elif k == "docx":
            n_docx += 1
    var msg = "Your vault contains " + String(len(files)) + " file(s): "
    var parts = List[String]()
    if n_pdf > 0:
        parts.append(String(n_pdf) + " PDF" + ("s" if n_pdf > 1 else ""))
    if n_csv > 0:
        parts.append(String(n_csv) + " CSV" + ("s" if n_csv > 1 else ""))
    if n_md > 0:
        parts.append(String(n_md) + " Markdown" + ("s" if n_md > 1 else ""))
    if n_docx > 0:
        parts.append(String(n_docx) + " Word (.docx)" + ("s" if n_docx > 1 else ""))
    for i in range(len(parts)):
        if i > 0 and i == len(parts) - 1:
            msg += " and "
        elif i > 0:
            msg += ", "
        msg += parts[i]
    msg += "."
    print_answer(msg)