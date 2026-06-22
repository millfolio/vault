"""Vault — the tool surface a privacy_box-generated program imports via
`from vault import *`.

This is the confidentiality boundary on the *tool* side: the generated program
(written by the untrusted frontier model) knows files only by their ALIASES
(`file_0`, ...). Every tool here takes an alias, resolves it to a real path
internally (via the manifest), and never returns or exposes the real path.

The tool contract (signatures + semantics) matches privacy_box/resources/
privacy_box-system.md exactly:

  manifest()                       -> List[FileInfo]   (.alias / .kind / .size / .columns)
  search(query, k)                 -> List[Chunk]      (.file_alias / .text / .score)
  csv_rows(alias)                  -> List[List[String]]
  pdf_text(alias)                  -> String
  md_text(alias)                   -> String
  ask_local(instruction, content)  -> String           (trusted on-device reader)
  print_answer(s)                  -> None

The vault dir + the local model URLs come from the environment so the generated
program needs no configuration. One inference-server process now serves BOTH a
chat model and the embedding model on a single port (its /v1/embeddings routes
to a secondary Qwen3-Embedding model), so chat + embeddings default to the same
base. The URLs are still separate env knobs in case you run two instances:
  MILLFOLIO_VAULT      (default ~/.config/millfolio/vault)
  MILLFOLIO_LOCAL_URL  (default http://127.0.0.1:8000/v1)  — CHAT (ask_local)
  MILLFOLIO_EMBED_URL  (default http://127.0.0.1:8000/v1)  — EMBEDDINGS (search)
  MILLFOLIO_LOCAL_MODEL(default "local")                   — chat model name

Both URLs are 127.0.0.1: the only network the run sandbox permits is loopback,
so nothing the generated program does can leave the machine.
"""

from std.os import getenv

from flare.http import HttpClient, Request

from manifest import build_manifest, FileInfo
import readers
import index
from index import Chunk, vault_files
from dates import iso_date as _iso_date


# ── A frontier-visible file view (`.alias` per the contract; aliases manifest.id) ──

@fieldwise_init
struct VaultFile(Copyable, Movable):
    # `alias` is a reserved keyword, so the field is DECLARED with backticks; a
    # generated program reads it as plain `.alias` (member access doesn't need
    # the escape), matching the privacy_box-system.md contract exactly.
    var `alias`: String         # the alias, e.g. "file_0" (== manifest FileInfo.id)
    var kind: String            # "csv" | "pdf" | "md"
    var size: Int
    var columns: List[String]   # aliased csv columns (col_0..); empty otherwise


# ── config from env ───────────────────────────────────────────────────────────

def _vault_dir() raises -> String:
    var d = getenv("MILLFOLIO_VAULT", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/.config/millfolio/vault"


def _local_url() raises -> String:
    """CHAT endpoint — ask_local talks to this. Default :8000."""
    return getenv("MILLFOLIO_LOCAL_URL", "http://127.0.0.1:8000/v1")


def _embed_url() raises -> String:
    """EMBEDDINGS endpoint — search() embeds the query here. Defaults to the SAME
    base as the chat endpoint (:8000): one inference-server process now serves
    both a chat model and the embedding model on one port (its /v1/embeddings
    routes to the secondary Qwen3-Embedding model). Override with MILLFOLIO_EMBED_URL
    to point at a separate embedding server if you still run two instances."""
    return getenv("MILLFOLIO_EMBED_URL", "http://127.0.0.1:8000/v1")


def _local_model() raises -> String:
    return getenv("MILLFOLIO_LOCAL_MODEL", "local")


# ── alias resolution (internal — real paths never leave this function) ────────

def _resolve(file_id: String) raises -> FileInfo:
    # vault_files() prefers the persisted index manifest (the same aliases search()
    # returns), falling back to a live walk of the served dir only when unindexed.
    var infos = vault_files(_vault_dir())
    for i in range(len(infos)):
        if infos[i].id == file_id:
            return infos[i].copy()
    raise Error("vault: unknown file alias '" + file_id + "'")


# ── tools ─────────────────────────────────────────────────────────────────────

def manifest() raises -> List[VaultFile]:
    """The aliased, frontier-visible file list — aliases, kinds, sizes, and the
    aliased CSV column schema. No paths, names, or contents."""
    var infos = vault_files(_vault_dir())
    var out = List[VaultFile]()
    for i in range(len(infos)):
        ref fi = infos[i]
        out.append(VaultFile(fi.id.copy(), fi.kind.copy(), fi.size, fi.columns.copy()))
    return out^


def search(query: String, k: Int) raises -> List[Chunk]:
    """Semantic search across the indexed vault -> ranked chunks (`.file_alias`,
    `.text`, `.score`). Embeds the query on-device (the EMBED endpoint) and
    k-NNs the LanceDB store. Uses _embed_url(), NOT the chat url — search needs
    the embedding model."""
    return index.search(query, k, _embed_url())


def csv_rows(file_alias: String) raises -> List[List[String]]:
    """Rows of a CSV file (by alias); each row is its trimmed string fields.
    Header row included as row 0."""
    var fi = _resolve(file_alias)
    if fi.kind != "csv":
        raise Error("vault.csv_rows: " + file_alias + " is not a csv (it's " + fi.kind + ")")
    return readers.csv_rows(fi.path)


def pdf_text(file_alias: String) raises -> String:
    """Extracted text of a PDF file (by alias)."""
    var fi = _resolve(file_alias)
    if fi.kind != "pdf":
        raise Error("vault.pdf_text: " + file_alias + " is not a pdf (it's " + fi.kind + ")")
    return readers.pdf_text(fi.path)


def md_text(file_alias: String) raises -> String:
    """Text of a markdown file (by alias)."""
    var fi = _resolve(file_alias)
    if fi.kind != "md":
        raise Error("vault.md_text: " + file_alias + " is not a md file (it's " + fi.kind + ")")
    return readers.md_text(fi.path)


def docx_text(file_alias: String) raises -> String:
    """Extracted text of a Word .docx file (by alias)."""
    var fi = _resolve(file_alias)
    if fi.kind != "docx":
        raise Error("vault.docx_text: " + file_alias + " is not a docx (it's " + fi.kind + ")")
    return readers.docx_text(fi.path)


def ask_local(instruction: String, content: String) raises -> String:
    """The trusted on-device reader: POST `instruction` + real `content` to the
    local chat-completions endpoint and return the assistant's reply. This is the
    ONLY tool that sees real content as text; it runs locally and never egresses.
    Mirrors privacy_box transport.LocalClient.chat."""
    var msg = instruction + "\n\n" + content
    var body = String('{"model":"') + _local_model() + '","messages":[{"role":"user","content":"'
    body += _json_escape(msg) + '"}]}'
    var req = Request(
        method="POST",
        url=_local_url() + "/chat/completions",
        body=List[UInt8](body.as_bytes()),
    )
    req.headers.set("content-type", "application/json")
    var client = HttpClient()
    var resp = client.send(req)
    return resp.json()["choices"][0]["message"]["content"].string_value()


def print_answer(s: String):
    """Emit the final answer to the user (local only)."""
    print(s)


def iso_date(year: Int, md: String) raises -> String:
    """Fold a bank-statement `M/D` (or `MM/DD`, `M/D/YY`) date together with the
    statement's `year` into a sortable `"YYYY-MM-DD"` string; `""` if it isn't a
    date. Statement lines show month/day only — the year is in the header — so a
    program reads the year once, then folds each transaction's M/D with it.
    Compare/sort the results with plain `<`."""
    return _iso_date(year, md)


# ── helpers ───────────────────────────────────────────────────────────────────

def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o^
