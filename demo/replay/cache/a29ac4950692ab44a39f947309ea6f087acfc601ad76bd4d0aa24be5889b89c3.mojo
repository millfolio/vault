from vault import *

def main() raises:
    var files = manifest()
    # Collect all PDF files as candidates for insurance documents
    var pdf_aliases = List[String]()
    for i in range(len(files)):
        if files[i].kind == "pdf":
            pdf_aliases.append(files[i].alias)

    # First, use search to find the most relevant passages about insurance coverage
    var hits = search("insurance coverage policy benefits covered", 20)

    # Gather the texts from search hits
    var relevant_texts = List[String]()
    var seen_aliases = List[String]()

    for i in range(len(hits)):
        progress("reviewing search result " + String(i+1) + "/" + String(len(hits)))
        var hit_text = hits[i].text
        var hit_alias = hits[i].file_alias
        relevant_texts.append(hit_text)
        # Track which files we found relevant content in
        var already = False
        for j in range(len(seen_aliases)):
            if seen_aliases[j] == hit_alias:
                already = True
                break
        if not already:
            seen_aliases.append(hit_alias)

    # Also read the full text of any PDF files that appeared in search results
    var full_texts = List[String]()
    var full_aliases = List[String]()
    for i in range(len(seen_aliases)):
        progress("reading file " + String(i+1) + "/" + String(len(seen_aliases)))
        var sa = seen_aliases[i]
        # Check if it's a pdf
        for j in range(len(files)):
            if files[j].alias == sa and files[j].kind == "pdf":
                var txt = pdf_text(sa)
                full_texts.append(txt)
                full_aliases.append(sa)
                break

    # If no relevant files found via search, read all PDFs
    if len(full_texts) == 0:
        for i in range(len(pdf_aliases)):
            progress("reading pdf " + String(i+1) + "/" + String(len(pdf_aliases)))
            var txt = pdf_text(pdf_aliases[i])
            full_texts.append(txt)
            full_aliases.append(pdf_aliases[i])

    # Ask local model to summarize what the insurance covers from each document
    var answers = ask_local_batch(
        "Use ONLY the text provided. If this text is from an insurance policy or document,"
        " summarize clearly what is covered (e.g. covered services, events, items, conditions,"
        " amounts, limits, exclusions). Be specific and concise. If the text does not contain"
        " insurance coverage information, reply exactly 'none'. Do not guess or invent.",
        full_texts)

    # Collect meaningful answers
    var coverage_parts = List[String]()
    for i in range(len(answers)):
        var ans = String(answers[i].strip())
        if ans != "none" and ans != "" and len(ans) > 10:
            coverage_parts.append(ans)

    if len(coverage_parts) == 0:
        # Try the raw search hit chunks as a fallback
        var chunk_answers = ask_local_batch(
            "Use ONLY the text provided. If this text describes what an insurance policy covers,"
            " extract that coverage information concisely. If it does not contain insurance"
            " coverage details, reply exactly 'none'. Do not guess or invent.",
            relevant_texts)
        for i in range(len(chunk_answers)):
            var ans = String(chunk_answers[i].strip())
            if ans != "none" and ans != "" and len(ans) > 10:
                coverage_parts.append(ans)

    if len(coverage_parts) == 0:
        print_answer("I couldn't find any insurance coverage details in your vault.")
        return

    # Combine all coverage parts into one answer via ask_local
    var combined = String("")
    for i in range(len(coverage_parts)):
        combined = combined + "\n\n--- Section " + String(i+1) + " ---\n" + coverage_parts[i]

    var summary = ask_local(
        "Use ONLY the text provided. Produce a clear, organized summary of what the insurance"
        " covers. Include covered items/services, key limits or amounts, and any notable"
        " exclusions if mentioned. Use bullet points or short paragraphs. Do not guess or invent."
        " Use ONLY information explicitly stated in the text.",
        combined)

    var final_ans = String(summary.strip())
    if final_ans == "" or final_ans == "none":
        print_answer("I found insurance documents but couldn't clearly extract coverage details.")
    else:
        print_answer("Here is what your insurance covers:\n\n" + final_ans)