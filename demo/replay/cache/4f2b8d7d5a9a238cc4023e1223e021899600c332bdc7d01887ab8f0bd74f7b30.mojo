from vault import *

def main() raises:
    var files = manifest()
    var insurance_files = List[String]()

    # First, search for insurance-related content
    var hits = search("insurance coverage policy benefits covered", 12)

    # Collect unique file aliases that look relevant
    var seen = List[String]()
    for i in range(len(hits)):
        var fa = hits[i].file_alias
        var already = False
        for s in range(len(seen)):
            if seen[s] == fa:
                already = True
                break
        if not already:
            seen.append(fa)

    # Also scan all PDFs since insurance docs are typically PDFs
    for i in range(len(files)):
        if files[i].kind == "pdf":
            var already = False
            for s in range(len(seen)):
                if seen[s] == files[i].alias:
                    already = True
                    break
            if not already:
                seen.append(files[i].alias)

    if len(seen) == 0:
        print_answer("I couldn't find any insurance documents in your vault.")
        return

    # Extract full text from each candidate PDF and ask about coverage
    var texts = List[String]()
    var aliases = List[String]()

    for i in range(len(seen)):
        progress("reading " + seen[i] + " (" + String(i+1) + "/" + String(len(seen)) + ")")
        # Find the kind for this alias
        var kind = String("")
        for f in range(len(files)):
            if files[f].alias == seen[i]:
                kind = files[f].kind
                break
        var content = String("")
        if kind == "pdf":
            content = pdf_text(seen[i])
        elif kind == "md":
            content = md_text(seen[i])
        elif kind == "docx":
            content = docx_text(seen[i])
        if content != "":
            texts.append(content)
            aliases.append(seen[i])

    if len(texts) == 0:
        print_answer("I couldn't read any insurance documents in your vault.")
        return

    # Ask local model to extract coverage details from each document
    var answers = ask_local_batch(
        "You are reading an insurance policy or related document. "
        "List what this insurance COVERS (covered items, benefits, inclusions). "
        "Be concise but complete — use bullet points if multiple items. "
        "If this document does not describe insurance coverage, reply exactly 'none'. "
        "Use ONLY the text provided. Do not guess or invent.", texts)

    var found = False
    var summary = String("")

    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans == "none" or ans == "":
            continue
        if not found:
            found = True
            summary = ans
        else:
            summary = summary + "\n\n--- Additional policy ---\n" + ans

    if found:
        print_answer("Here is what your insurance covers:\n\n" + summary)
    else:
        print_answer("I found some documents but couldn't identify specific insurance coverage details. Try checking your policy documents directly.")