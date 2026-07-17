from vault import *

def main() raises:
    var files = manifest()

    # Search for insurance-related content
    var hits = search("insurance coverage policy benefits covered", 20)

    # Collect chunks from search results
    var chunks = List[String]()
    var sources = List[String]()
    for i in range(len(hits)):
        if hits[i].score > 0.3:
            chunks.append(hits[i].text)
            sources.append(hits[i].file_alias)

    # Also scan all PDFs fully for insurance coverage info
    for i in range(len(files)):
        if files[i].kind == "pdf":
            progress("scanning " + files[i].alias + " for coverage details")
            var fc = file_chunks(files[i].alias)
            for c in range(len(fc)):
                var already = False
                for s in range(len(sources)):
                    if sources[s] == files[i].alias and chunks[s] == fc[c]:
                        already = True
                        break
                if not already:
                    chunks.append(fc[c])
                    sources.append(files[i].alias)

    if len(chunks) == 0:
        print_answer("I couldn't find any insurance documents in your vault.")
        return

    # Ask local model to extract coverage info from each chunk
    var answers = ask_local_batch(
        "Use ONLY the text provided. If this text describes what an insurance policy covers"
        " (covered items, benefits, included services, exclusions, coverage amounts, or policy details),"
        " summarize the coverage information concisely. Otherwise reply exactly 'none'."
        " Do not guess or invent. Use ONLY the text provided.", chunks)

    var found = List[String]()
    for i in range(len(answers)):
        var a = String(answers[i].strip())
        if a != "none" and a != "" and a.byte_length() > 5:
            # Avoid duplicates
            var dup = False
            for j in range(len(found)):
                if found[j] == a:
                    dup = True
                    break
            if not dup:
                found.append(a)

    if len(found) == 0:
        print_answer("I found insurance-related documents in your vault but couldn't extract specific coverage details from them. Try asking about a specific type of coverage.")
        return

    # Combine all coverage details
    var summary = String("")
    for i in range(len(found)):
        if i > 0:
            summary += "\n\n"
        summary += found[i]

    # Ask the local model to produce a final coherent summary
    var final_summary = ask_local(
        "Use ONLY the text provided. Summarize what the insurance covers in clear, organized bullet points."
        " Group related items together. Do not guess or invent anything not in the text."
        " If you cannot determine coverage details, reply 'none'.",
        summary)

    var fs = String(final_summary.strip())
    if fs == "none" or fs == "":
        print_answer("I found some insurance documents but couldn't clearly identify the coverage details. Here is what I found:\n\n" + summary)
    else:
        print_answer("Based on your insurance documents, here is what your insurance covers:\n\n" + fs)