from vault import *

def main() raises:
    var hits = search("insurance coverage policy covers benefits included", 20)
    var coverage_info = List[String]()

    for i in range(len(hits)):
        progress("scanning chunk " + String(i + 1) + "/" + String(len(hits)))
        ref c = hits[i]
        var result = ask_local(
            "Use ONLY the text provided. Extract any information about what this insurance policy covers, including covered services, benefits, exclusions, or coverage limits. "
            "Return a concise summary of coverage details found. If the text does not clearly describe insurance coverage, reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var r = String(result.strip())
        if r != "none" and r != "":
            coverage_info.append(r)

    if len(coverage_info) == 0:
        # Try reading all PDFs directly
        var files = manifest()
        for i in range(len(files)):
            if files[i].kind == "pdf":
                progress("reading " + files[i].alias)
                var text = pdf_text(files[i].alias)
                var result = ask_local(
                    "Use ONLY the text provided. Summarize what this insurance policy covers, including covered services, benefits, and any notable exclusions or limits. "
                    "If this is not an insurance document or does not describe coverage, reply exactly 'none'. Do not guess or invent.",
                    text
                )
                var r = String(result.strip())
                if r != "none" and r != "":
                    coverage_info.append(r)

    if len(coverage_info) == 0:
        print_answer("I couldn't find insurance coverage details in your vault.")
        return

    # Combine all coverage info into one summary
    var combined = String("")
    for i in range(len(coverage_info)):
        if combined != "":
            combined = combined + "\n\n"
        combined = combined + coverage_info[i]

    var summary = ask_local(
        "Use ONLY the text provided. Produce a clear, organized summary of what the insurance covers. "
        "Group related items if possible (e.g. medical, dental, vision, exclusions, limits). "
        "Do not guess or invent anything not in the text.",
        combined
    )

    print_answer("Here is what your insurance covers:\n\n" + String(summary.strip()))