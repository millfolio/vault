"""manifest — the sanitized, frontier-visible view of the vault.

Scans a data directory and produces a list of `FileInfo`: each file gets an
*alias* (`file_0`, `file_1`, ...), its kind (`csv`/`pdf`/`md`), size, and — for
CSVs — the aliased column schema (`col_0`, `col_1`, ...). The real path is kept
on the trusted side (`FileInfo.path`) and is NEVER part of what reaches the
frontier model; only alias/kind/size/columns are.
"""

from std.os import listdir, makedirs
from std.os.path import isfile, getsize


@fieldwise_init
struct FileInfo(Copyable, Movable):
    var id: String              # the alias, e.g. "file_0"
    var path: String            # LOCAL ONLY — never sent to the frontier model
    var kind: String            # "csv" | "pdf" | "md"
    var size: Int
    var columns: List[String]   # aliased csv columns (col_0..); empty otherwise


def _lower_ascii(s: String) -> String:
    """ASCII-lowercase (enough for file extensions)."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:  # 'A'..'Z'
            c += 32
        out += chr(c)
    return out^


def _ext(name: String) -> String:
    """Lowercased extension of a filename, or "" if none."""
    if name.find(".") == -1:
        return String("")
    var parts = name.split(".")
    return _lower_ascii(String(parts[len(parts) - 1]))


def _kind_for(ext: String) -> String:
    """Map a file extension to a vault kind, or "" to skip."""
    if ext == "csv":
        return String("csv")
    if ext == "pdf":
        return String("pdf")
    if ext == "md" or ext == "markdown":
        return String("md")
    if ext == "docx":
        return String("docx")
    return String("")


def _csv_columns(path: String) raises -> List[String]:
    """Aliased column names (col_0..) from a CSV header row."""
    var out = List[String]()
    var text: String
    with open(path, "r") as f:
        text = f.read()
        if text.byte_length() == 0:
            return out^
        var lines = text.split("\n")
        var cols = String(lines[0]).split(",")
        for i in range(len(cols)):
            out.append(String("col_") + String(i))
    return out^


def _sort_names(mut names: List[String]):
    """In-place insertion sort so aliases are stable across runs."""
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j - 1] > names[j]:
            var tmp = names[j - 1].copy()
            names[j - 1] = names[j].copy()
            names[j] = tmp^
            j -= 1


def build_manifest(data_dir: String) raises -> List[FileInfo]:
    """Scan `data_dir` (top level) and build the aliased manifest. Files that
    aren't CSV/PDF/Markdown are skipped; aliases are assigned in sorted-name
    order for stability. A missing vault dir is created (empty) rather than an
    error — a clean machine has no vault yet."""
    makedirs(data_dir, exist_ok=True)
    var raw = listdir(data_dir)
    var names = List[String]()
    for i in range(len(raw)):
        names.append(String(raw[i]))
    _sort_names(names)

    var infos = List[FileInfo]()
    var idx = 0
    for i in range(len(names)):
        var name = names[i].copy()
        var path = data_dir + "/" + name
        if not isfile(path):
            continue
        var kind = _kind_for(_ext(name))
        if kind == "":
            continue
        var cols = List[String]()
        if kind == "csv":
            cols = _csv_columns(path)
        infos.append(
            FileInfo(String("file_") + String(idx), path, kind, getsize(path), cols^)
        )
        idx += 1
    return infos^
