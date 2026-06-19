"""Readers — turn a vault file into text the indexer/tools can use.

Three readers, one per vault kind:
  - `csv_rows(path)` -> rows of trimmed string fields (header row included; the
    caller decides whether to skip it).
  - `md_text(path)`  -> the file's text, verbatim.
  - `pdf_text(path)` -> extracted text via pdftotext.mojo (+ zlib for FlateDecode).

These take REAL paths and live on the trusted side. The alias->path resolution
happens in `vault.mojo`; nothing here knows about aliases.
"""

from pdf import read_file, extract_text
from csv import read as csv_read


def csv_rows(path: String) raises -> List[List[String]]:
    """Parse a CSV into rows of string fields, RFC-4180 style (csv.mojo).

    Quoted fields, embedded commas/newlines, and `""` escapes are handled; empty
    rows dropped; header included. Thin wrapper over the `csv` library so the
    parser is reusable (millrace/csv.mojo)."""
    return csv_read(path)


def md_text(path: String) raises -> String:
    """Read a markdown (or any text) file's contents verbatim."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    return text^


def pdf_text(path: String) raises -> String:
    """Extract text from a PDF via pdftotext.mojo.

    Reads the raw bytes and runs the extractor (which uses the zlib shim for
    /FlateDecode streams). Returns the raw extracted text — unlike the pdftotext
    CLI we do NOT escape control characters, since this feeds embedding/ask_local
    rather than a terminal.
    """
    var data = read_file(path)
    return extract_text(data)
