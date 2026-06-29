"""Manifest — the sanitized, frontier-visible view of the vault.

Scans a data directory and produces a list of `FileInfo`: each file gets an
*alias* (`file_0`, `file_1`, ...), its kind (`csv`/`pdf`/`md`), size, and — for
CSVs — the aliased column schema (`col_0`, `col_1`, ...). The real path is kept
on the trusted side (`FileInfo.path`) and is NEVER part of what reaches the
frontier model; only alias/kind/size/columns are.
"""

from std.os import listdir, makedirs
from std.os.path import isfile, isdir, getsize


@fieldwise_init
struct FileInfo(Copyable, Movable):
    var id: String  # the alias, e.g. "file_0"
    var path: String  # LOCAL ONLY — never sent to the frontier model
    var kind: String  # "csv" | "pdf" | "md"
    var size: Int
    var columns: List[String]  # aliased csv columns (col_0..); empty otherwise


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


def _name_of(path: String) -> String:
    """Last path component (filename) of `path`."""
    var parts = path.split("/")
    return String(parts[len(parts) - 1])


def _collect_files(dir: String, mut out: List[String]) raises:
    """Recursively collect every regular file under `dir`, depth-first. Hidden
    entries (leading `.` — `.git`, `.DS_Store`, dotfiles/dirs) are skipped so the
    index doesn't pull in VCS/system cruft."""
    var raw = listdir(dir)
    for i in range(len(raw)):
        var name = String(raw[i])
        if name.startswith("."):
            continue
        var p = dir + "/" + name
        if isdir(p):
            _collect_files(p, out)
        elif isfile(p):
            out.append(p.copy())


def manifest_for_files(paths_in: List[String]) raises -> List[FileInfo]:
    """Build the kind-filtered, alias-assigned `FileInfo` list for an EXPLICIT set
    of candidate file `paths` (sorted by full path for stable aliasing). Files that
    aren't CSV/PDF/Markdown/DOCX are skipped. Callers compute each file's vault
    name relative to the source base (`_relpath`); aliases here are positional.
    """
    var paths = paths_in.copy()
    _sort_names(paths)
    var infos = List[FileInfo]()
    var idx = 0
    for i in range(len(paths)):
        var path = paths[i].copy()
        var kind = _kind_for(_ext(_name_of(path)))
        if kind == "":
            continue
        var cols = List[String]()
        if kind == "csv":
            cols = _csv_columns(path)
        infos.append(
            FileInfo(
                String("file_") + String(idx), path, kind, getsize(path), cols^
            )
        )
        idx += 1
    return infos^


def build_manifest(data_dir: String) raises -> List[FileInfo]:
    """Scan `data_dir` RECURSIVELY (subfolders included) and build the aliased
    manifest. Files that aren't CSV/PDF/Markdown/DOCX are skipped; aliases are
    assigned in sorted-path order for stability. `FileInfo.path` is the full real
    path (local-only); a file's identity within the vault is its path RELATIVE to
    `data_dir` (e.g. `reports/q1.pdf`), so same-named files in different subfolders
    don't collide. A missing vault dir is created (empty) rather than an error.
    """
    makedirs(data_dir, exist_ok=True)
    var paths = List[String]()
    _collect_files(data_dir, paths)
    return manifest_for_files(paths)


def collect_index_paths(roots: List[String]) raises -> List[String]:
    """Every indexable candidate file across `roots`: a DIRECTORY root is walked
    recursively (`_collect_files`); a FILE root is taken as-is. Non-existent roots
    are skipped (the CLI validates existence before we get here)."""
    var out = List[String]()
    for r in range(len(roots)):
        var root = roots[r]
        if isdir(root):
            _collect_files(root, out)
        elif isfile(root):
            out.append(root.copy())
    return out^


def _last_slash(s: String) -> Int:
    """Byte index of the last '/' in `s`, or -1 if none."""
    var b = s.as_bytes()
    var idx = -1
    for i in range(len(b)):
        if b[i] == 47:  # '/'
            idx = i
    return idx


def _dirname(path: String) raises -> String:
    """The directory containing `path` (everything before the last '/'). '/' for a
    root-level entry, '.' when there's no slash at all."""
    var i = _last_slash(path)
    if i < 0:
        return String(".")
    if i == 0:
        return String("/")
    return String(path[byte=:i])


def common_base(roots: List[String]) raises -> String:
    """The directory all `roots` live under — used as the index `source_dir`, with
    every file then named RELATIVE to it. A single directory root IS its own base
    (names stay relative to it, e.g. `reports/q1.pdf`, preserving the original
    single-folder behaviour); a single file's base is its parent dir; multiple
    roots use their longest common ancestor directory (so e.g. indexing `WF/` and
    `Chase/` names files `WF/…` and `Chase/…` with no collisions)."""
    if len(roots) == 0:
        return String(".")
    if len(roots) == 1:
        return roots[0].copy() if isdir(roots[0]) else _dirname(roots[0])
    # Longest common component-wise prefix of the roots (abs paths split to
    # ["", "a", "b", …]; the leading "" keeps the root slash).
    var common = List[String]()
    var first = roots[0].split("/")
    for p in range(len(first)):
        common.append(String(first[p]))
    for r in range(1, len(roots)):
        var parts = roots[r].split("/")
        var n = len(common) if len(common) < len(parts) else len(parts)
        var k = 0
        while k < n and common[k] == String(parts[k]):
            k += 1
        var trunc = List[String]()
        for j in range(k):
            trunc.append(common[j].copy())
        common = trunc^
    var base = String("")
    for j in range(len(common)):
        if j > 0:
            base += "/"
        base += common[j]
    # All-absolute roots that share only "/" collapse to "" above → restore "/".
    if base == "" and roots[0].byte_length() > 0 and roots[0].startswith("/"):
        return String("/")
    return base^
