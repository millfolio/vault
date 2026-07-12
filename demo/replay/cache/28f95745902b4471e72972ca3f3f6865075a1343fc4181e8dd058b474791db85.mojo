from vault import *

def main() raises:
    var hits = search("insurance coverage policy covers benefits included", 12)
    var chunks = List[String]()
    var sources = List[String]()
    for i in range(len(hits)):
        chunks.append(hits[i].text)
        sources.append(hits[i].file_alias)

    if len(chunks) == 0:
        print_answer("I couldn't find any insurance policy information in your vault.")
        return

    progress("reading " + String(len(chunks)) + " insurance-related passages...")

    var answers = ask_local_batch(
        "Use ONLY the text provided. If this passage describes what an insurance policy covers"
        " (e.g. covered events, included benefits, exclusions, coverage types, limits),"
        " summarize the coverage details clearly and concisely. If it does not contain"
        " coverage information, reply exactly 'none'. Do not guess or invent.",
        chunks)

    var summary = String("")
    var seen_files = List[String]()
    for i in range(len(answers)):
        var r = String(answers[i].strip())
        if r == "none" or r == "":
            continue
        var already = False
        for j in range(len(seen_files)):
            if seen_files[j] == sources[i]:
                already = True
                break
        if already:
            continue
        seen_files.append(sources[i])
        if summary != "":
            summary = summary + "\n\n"
        summary = summary + r

    if summary == "":
        var all_chunks = List[String]()
        var all_sources = List[String]()
        var checked = List[String]()
        var files = manifest()
        for i in range(len(files)):
            progress("scanning " + String(i+1) + "/" + String(len(files)))
            var fc = file_chunks(files[i].alias)
            for c in range(len(fc)):
                all_chunks.append(fc[c])
                all_sources.append(files[i].alias)
        var ans2 = ask_local_batch(
            "Use ONLY the text provided. If this passage describes insurance coverage,"
            " benefits, what is or is not covered, or policy details, summarize those"
            " details concisely. If not relevant, reply exactly 'none'."
            " Do not guess or invent.",
            all_chunks)
        for i in range(len(ans2)):
            var r = String(ans2[i].strip())
            if r == "none" or r == "":
                continue
            var already = False
            for j in range(len(checked)):
                if checked[j] == all_sources[i]:
                    already = True
                    break
            if already:
                continue
            checked.append(all_sources[i])
            if summary != "":
                summary = summary + "\n\n"
            summary = summary + r

    if summary == "":
        print_answer("I couldn't find clear coverage details in your insurance documents.")
    else:
        print_answer("Here is what your insurance covers:\n\n" + summary)