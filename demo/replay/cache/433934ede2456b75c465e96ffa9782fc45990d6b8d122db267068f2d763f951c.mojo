from vault import *

def main() raises:
    var hits = search("insurance coverage benefits policy covers included", 20)
    
    var coverage_info = List[String]()
    
    for i in range(len(hits)):
        progress("scanning result " + String(i + 1) + "/" + String(len(hits)))
        ref c = hits[i]
        var result = ask_local(
            "Use ONLY the text provided. Extract any information about what this insurance policy covers, including benefits, covered services, exclusions, or coverage limits. Summarize concisely. If the text does not clearly contain insurance coverage information, reply exactly 'none'. Do not guess or invent.",
            c.text
        )
        var s = String(result.strip())
        if s != "none" and s != "":
            coverage_info.append(s)

    if len(coverage_info) == 0:
        # Try reading each PDF directly
        var files = manifest()
        for i in range(len(files)):
            progress("reading " + files[i].alias)
            if files[i].kind == "pdf":
                var text = pdf_text(files[i].alias)
                var result = ask_local(
                    "Use ONLY the text provided. This may be an insurance document. List what this insurance covers, including any benefits, covered services, coverage amounts, and exclusions. Be concise and clear. If the text does not clearly contain insurance coverage information, reply exactly 'none'. Do not guess or invent.",
                    text
                )
                var s = String(result.strip())
                if s != "none" and s != "":
                    coverage_info.append(s)

    if len(coverage_info) == 0:
        print_answer("I couldn't find insurance coverage details in your vault.")
        return

    var summary = ask_local_batch(
        "Use ONLY the text provided. This is a piece of insurance coverage information. Restate it clearly and concisely as a bullet point or short paragraph. If it is redundant or not useful coverage info, reply 'none'. Do not guess or invent.",
        coverage_info
    )

    var final_parts = List[String]()
    for i in range(len(summary)):
        var s = String(summary[i].strip())
        if s != "none" and s != "":
            final_parts.append("- " + s)

    if len(final_parts) == 0:
        print_answer("I found insurance documents but couldn't extract clear coverage details.")
        return

    var answer = String("Here is what your insurance covers:\n\n")
    for i in range(len(final_parts)):
        answer = answer + final_parts[i] + "\n"

    print_answer(answer)