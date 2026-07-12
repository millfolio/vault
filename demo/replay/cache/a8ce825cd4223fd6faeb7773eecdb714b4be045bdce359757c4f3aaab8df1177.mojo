from vault import *

def main() raises:
    var hits = search("insurance coverage benefits policy covers included", 16)
    var results = List[String]()
    for i in range(len(hits)):
        progress("scanning result " + String(i + 1) + "/" + String(len(hits)))
        ref c = hits[i]
        var ans = ask_local(
            "Use ONLY the text provided. List what is covered or included under this insurance policy "
            "(e.g. medical, dental, vision, liability, collision, property, etc.). "
            "Be concise and specific. If the text does not clearly describe insurance coverage, "
            "reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var s = String(ans.strip())
        if s != "none" and s != "":
            results.append(s)

    if len(results) == 0:
        var files = manifest()
        for i in range(len(files)):
            progress("reading full file " + files[i].id)
            var fid = files[i].id
            var fkind = files[i].kind
            var text = String("")
            if fkind == "pdf":
                text = pdf_text(fid)
            elif fkind == "md":
                text = md_text(fid)
            elif fkind == "docx":
                text = docx_text(fid)
            else:
                continue
            var ans = ask_local(
                "Use ONLY the text provided. Summarize what this insurance policy covers — "
                "list all covered items, services, or protections mentioned. "
                "Be concise and specific. If this is not an insurance document or coverage details "
                "are not present, reply exactly 'none'. Do not guess or invent.",
                text
            )
            var s = String(ans.strip())
            if s != "none" and s != "":
                results.append(s)

    if len(results) == 0:
        print_answer("I couldn't find insurance coverage details in your vault.")
        return

    var combined = String("")
    for i in range(len(results)):
        combined = combined + "\n\n--- Section " + String(i + 1) + " ---\n" + results[i]

    var summary = ask_local(
        "Use ONLY the text provided. Produce a clear, concise summary of what the insurance covers. "
        "Organize by category if possible (e.g. Medical, Dental, Vehicle, Property, Liability, etc.). "
        "Do not repeat yourself. Do not guess or invent anything not in the text.",
        combined
    )

    print_answer("Here is what your insurance covers:\n\n" + String(summary.strip()))