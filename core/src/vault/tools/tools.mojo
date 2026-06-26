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
  progress(msg)                    -> None               (live progress line — fd 1, unbuffered)

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
from std.ffi import external_call, c_char
from std.memory import UnsafePointer
from std.time import perf_counter_ns

from flare.http import HttpClient, Request

from vault.index import build_manifest, FileInfo
import vault.index.readers as readers
import vault.index as index
from vault.index import Chunk, vault_files
from vault.extract import Txn
from vault.extract.dates import iso_date as _iso_date
from vault.extract.amounts import parse_amount as _parse_amount
from vault.extract.amounts import format_money as _format_money


# The SENTINEL that prefixes a progress line on stdout. A `progress(msg)` call
# writes `PROGRESS_SENTINEL + msg + "\n"` to fd 1; the server recognizes lines
# with this prefix and streams them to the chat as live status, stripping them
# from the final reply. \x1f (US, "unit separator") can't appear in a normal
# answer, so it can't be spoofed by ordinary print_answer text. The orchestrator
# + server hold a matching copy of this exact string — keep them in lockstep.
comptime PROGRESS_SENTINEL = "\x1f@@progress@@\x1f"

# Sentinel for a per-engine-call timing line: `STAT_SENTINEL + <tool>\t<ms>\n` on
# fd 1 (same unbuffered raw-write channel as progress). The server aggregates these
# (count + duration per tool) and shows a one-line summary before the final answer,
# then strips them from the reply. \x1f can't appear in real answer text.
comptime STAT_SENTINEL = "\x1f@@stat@@\x1f"


def _stat(tool: String, ms: Float64):
    """Emit a timing line for one engine call (ask_local/search) to fd 1, unbuffered
    (see `progress` for why raw write(2), not print)."""
    var line = String(STAT_SENTINEL) + tool + "\t" + String(ms) + "\n"
    var b = line.as_bytes()
    var p = b.unsafe_ptr()
    var n = len(b)
    _ = external_call["write", Int](Int(1), p, Int(n))


def _stat_model(prefill_tok: Int, gen_tok: Int, prefill_ms: Float64, decode_ms: Float64):
    """Emit a MODEL-stats line for one chat call — prefill/gen token counts + their
    wall-clock — read from the engine response's non-standard `millfolio` field. Same
    unbuffered fd-1 channel as `_stat`; the server aggregates these into the live
    working line + the final prefill/gen throughput (tok/s). Format keeps `model` as
    the first field so the server tells it apart from the 2-field API stat line."""
    var line = (
        String(STAT_SENTINEL) + "model\t" + String(prefill_tok) + "\t"
        + String(gen_tok) + "\t" + String(prefill_ms) + "\t" + String(decode_ms) + "\n")
    var b = line.as_bytes()
    _ = external_call["write", Int](Int(1), b.unsafe_ptr(), Int(len(b)))


def _int_after(s: String, key: String) -> Int:
    """The integer immediately following `key` in `s` (skipping one ':' + spaces);
    -1 if `key` is absent. A tiny scanner used to read the engine's `millfolio`
    stats from the RAW response text — the Mojo json lib aborts (uncatchable
    debug_assert) indexing that trailing nested object."""
    var i = s.find(key)
    if i == -1:
        return -1
    i += len(key)
    var b = s.as_bytes()
    while i < len(b) and (Int(b[i]) == 32 or Int(b[i]) == 58):  # spaces / ':'
        i += 1
    var n = 0
    var any = False
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        n = n * 10 + (Int(b[i]) - 48)
        any = True
        i += 1
    return n if any else -1


def _stat_model_from_raw(raw: String):
    """Emit model stats parsed from the RAW chat response text. No-op when the
    `millfolio` field is absent (a non-millfolio endpoint). All four fields are
    integers in the response."""
    var gen = _int_after(raw, '"gen_tokens"')
    if gen < 0:
        return  # not a millfolio engine response
    var pf = _int_after(raw, '"prompt_tokens"')
    var pfms = _int_after(raw, '"prefill_ms"')
    var decms = _int_after(raw, '"decode_ms"')
    _stat_model(
        pf if pf >= 0 else 0, gen,
        Float64(pfms if pfms >= 0 else 0), Float64(decms if decms >= 0 else 0))


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
    var t0 = perf_counter_ns()
    var infos = vault_files(_vault_dir())
    var out = List[VaultFile]()
    for i in range(len(infos)):
        ref fi = infos[i]
        out.append(VaultFile(fi.id.copy(), fi.kind.copy(), fi.size, fi.columns.copy()))
    _stat("manifest", Float64(perf_counter_ns() - t0) / 1.0e6)
    return out^


def search(query: String, k: Int) raises -> List[Chunk]:
    """Semantic search across the indexed vault -> ranked chunks (`.file_alias`,
    `.text`, `.score`). Embeds the query on-device (the EMBED endpoint) and
    k-NNs the LanceDB store. Uses _embed_url(), NOT the chat url — search needs
    the embedding model."""
    var t0 = perf_counter_ns()
    var r = index.search(query, k, _embed_url())
    _stat("search", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def csv_rows(file_alias: String) raises -> List[List[String]]:
    """Rows of a CSV file (by alias); each row is its trimmed string fields.
    Header row included as row 0."""
    var t0 = perf_counter_ns()
    var fi = _resolve(file_alias)
    if fi.kind != "csv":
        raise Error("vault.csv_rows: " + file_alias + " is not a csv (it's " + fi.kind + ")")
    var r = readers.csv_rows(fi.path)
    _stat("csv_rows", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def pdf_text(file_alias: String) raises -> String:
    """Extracted text of a PDF file (by alias)."""
    var t0 = perf_counter_ns()
    var fi = _resolve(file_alias)
    if fi.kind != "pdf":
        raise Error("vault.pdf_text: " + file_alias + " is not a pdf (it's " + fi.kind + ")")
    var r = readers.pdf_text(fi.path)
    _stat("pdf_text", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def md_text(file_alias: String) raises -> String:
    """Text of a markdown file (by alias)."""
    var t0 = perf_counter_ns()
    var fi = _resolve(file_alias)
    if fi.kind != "md":
        raise Error("vault.md_text: " + file_alias + " is not a md file (it's " + fi.kind + ")")
    var r = readers.md_text(fi.path)
    _stat("md_text", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def docx_text(file_alias: String) raises -> String:
    """Extracted text of a Word .docx file (by alias)."""
    var t0 = perf_counter_ns()
    var fi = _resolve(file_alias)
    if fi.kind != "docx":
        raise Error("vault.docx_text: " + file_alias + " is not a docx (it's " + fi.kind + ")")
    var r = readers.docx_text(fi.path)
    _stat("docx_text", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def file_chunks(file_alias: String) raises -> List[String]:
    """EVERY indexed chunk of a file, in document order — COMPLETE coverage for
    enumeration (count / sum / max), unlike `search()`'s similarity-ranked top-k
    which only sees ~k chunks and structurally undercounts aggregations. Reuses the
    text the index already extracted (no re-reading the file). Use this to scan an
    entire file's content. `[]` for an unknown alias or an unindexed vault."""
    var t0 = perf_counter_ns()
    var r = index.file_chunks(file_alias)
    _stat("file_chunks", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def transactions(file_alias: String) raises -> List[Txn]:
    """The reconcile-VERIFIED structured transactions of a statement file: a list of
    `Txn` with `.date` (raw `M/D`), `.desc` (merchant/description), `.amount` (a
    non-negative magnitude), and `.direction` (`"credit"` money-in / `"debit"`
    money-out). Extracted ONCE at index time and kept ONLY when they reconcile
    against the statement's own arithmetic (running balance or printed totals), so
    these are exact — count = `len`, total = `sum(.amount)`, biggest = `max(.amount)`,
    no per-row model call. EMPTY when the file isn't a statement, has none, or
    couldn't be reconciled — then fall back to `file_chunks()` + `ask_local`."""
    var t0 = perf_counter_ns()
    var r = index.file_transactions(file_alias)
    _stat("transactions", Float64(perf_counter_ns() - t0) / 1.0e6)
    return r^


def ask_local(instruction: String, content: String) raises -> String:
    """The trusted on-device reader: POST `instruction` + real `content` to the
    local chat-completions endpoint and return the assistant's reply. This is the
    ONLY tool that sees real content as text; it runs locally and never egresses.
    Mirrors privacy_box transport.LocalClient.chat."""
    var msg = instruction + "\n\n" + content
    var body = String('{"model":"') + _local_model() + '","messages":[{"role":"user","content":"'
    body += _json_escape(msg) + '"}]}'
    # One retry, then give up gracefully: the local server can return a transient,
    # garbled, or truncated response (it was busy, mid-restart, or the body framing
    # was off) and a single bad reply must NOT crash a whole sum/scan loop — the
    # caller treats "" like "none" and skips that chunk. Catches HTTP + JSON-parse
    # errors alike ("trailing content after top-level JSON value").
    var t0 = perf_counter_ns()
    var attempt = 0
    while attempt < 2:
        try:
            var req = Request(
                method="POST",
                url=_local_url() + "/chat/completions",
                body=List[UInt8](body.as_bytes()),
            )
            req.headers.set("content-type", "application/json")
            var client = HttpClient()
            var resp = client.send(req)
            var raw = resp.text()
            var out = resp.json()["choices"][0]["message"]["content"].string_value()
            _stat("ask_local", Float64(perf_counter_ns() - t0) / 1.0e6)
            # Engine prefill/gen stats ride in the non-standard `millfolio` field. The
            # Mojo json lib crashes (uncatchable debug_assert) indexing that trailing
            # nested object, so parse the numbers straight from the raw response text.
            _stat_model_from_raw(raw)
            return out
        except:
            attempt += 1
    _stat("ask_local", Float64(perf_counter_ns() - t0) / 1.0e6)
    return String("")


def _lead_int(s: String) -> Int:
    """Leading integer of `s` (after optional spaces); -1 if none — for parsing the
    `<n>:` prefix of a batched answer line."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and Int(b[i]) == 32:
        i += 1
    var n = 0
    var any = False
    while i < len(b) and Int(b[i]) >= 48 and Int(b[i]) <= 57:
        n = n * 10 + (Int(b[i]) - 48)
        any = True
        i += 1
    return n if any else -1


def _batch_call(instruction: String, items: List[String]) raises -> List[String]:
    """One on-device model call for a SMALL group (≤ _BATCH) of snippets — returns
    one answer per item, aligned by index. Internal; callers use `ask_local_batch`."""
    var n = len(items)
    var out = List[String]()
    var k = 0
    while k < n:
        out.append(String("none"))
        k += 1
    if n == 0:
        return out^
    # One numbered prompt: the model answers each snippet on its own `<n>: <answer>` line.
    var prompt = instruction
    prompt += "\n\nApply the instruction to EACH numbered snippet below. Reply with"
    prompt += " EXACTLY one line per snippet, formatted `<n>: <answer>` (use 'none'"
    prompt += " when it does not apply). Output nothing else.\n\n"
    for i in range(n):
        prompt += String(i + 1) + ": " + _replace_all(items[i], "\n", " ") + "\n"

    var t0 = perf_counter_ns()
    var body = String('{"model":"') + _local_model() + '","messages":[{"role":"user","content":"'
    body += _json_escape(prompt) + '"}]}'
    var reply = String("")
    var attempt = 0
    while attempt < 2:
        try:
            var req = Request(
                method="POST",
                url=_local_url() + "/chat/completions",
                body=List[UInt8](body.as_bytes()),
            )
            req.headers.set("content-type", "application/json")
            var client = HttpClient()
            var resp = client.send(req)
            var raw = resp.text()
            reply = resp.json()["choices"][0]["message"]["content"].string_value()
            _stat_model_from_raw(raw)  # millfolio stats from raw text (json lib aborts on it)
            break
        except:
            attempt += 1
    _stat("ask_local", Float64(perf_counter_ns() - t0) / 1.0e6)

    # Parse "<n>: <answer>" lines into the aligned result (split on the FIRST ':',
    # rejoining the rest so an answer that contains ':' survives).
    var lines = reply.split("\n")
    for li in range(len(lines)):
        var ln = String(lines[li])
        var idx = _lead_int(ln)
        if idx < 1 or idx > n:
            continue
        var parts = ln.split(":")
        if len(parts) < 2:
            continue
        var ans = String("")
        for pi in range(1, len(parts)):
            if pi > 1:
                ans += ":"
            ans += String(parts[pi])
        out[idx - 1] = String(ans.strip())
    return out^


comptime _BATCH = 10   # snippets per on-device model call


def ask_local_batch(instruction: String, items: List[String]) raises -> List[String]:
    """Apply `instruction` to MANY snippets and return one answer per item, aligned by
    index — but in just ⌈len(items)/10⌉ on-device model calls instead of one per item
    (each `ask_local` is slow). Pass ALL your candidate texts; this batches them
    internally (~10 per call), reports live progress, and concatenates the answers.
    A missing/garbled item is "none". This is the FAST way to do sum / scan / max:
        var ans = ask_local_batch("... reply the amount or none ...", texts)
        for a in range(len(ans)): total += parse_amount(String(ans[a]))"""
    var out = List[String]()
    var i = 0
    while i < len(items):
        var group = List[String]()
        var j = i
        while j < len(items) and j < i + _BATCH:
            group.append(items[j].copy())
            j += 1
        progress("reading " + String(j) + "/" + String(len(items)))
        var res = _batch_call(instruction, group)
        for r in range(len(res)):
            out.append(res[r].copy())
        i = j
    return out^


def print_answer(s: String):
    """Emit the final answer to the user (local only)."""
    print(s)


def progress(msg: String):
    """Report a one-line progress update to the user while the program runs (e.g.
    its scan position). Call it at loop boundaries — it's free and never sees data.

    Writes `PROGRESS_SENTINEL + msg + "\\n"` straight to fd 1 with the raw libc
    `write(2)` syscall — NOT `print()`. This is deliberate: the run sandbox
    redirects stdout to a capture file, and over a file Mojo/libc stdio is
    FULL-buffered, so a `print()` here would sit in the buffer until the program
    exits — defeating LIVE streaming. `write(2)` is unbuffered and lands in the
    file immediately, so the server's poller sees each progress line as it's
    emitted. `print_answer` stays a normal `print`: its buffer flushes at exit,
    AFTER every raw progress write, so the answer still comes last."""
    var line = String(PROGRESS_SENTINEL) + msg + "\n"
    var n = line.byte_length()
    var p = line.unsafe_ptr().bitcast[c_char]()
    _ = external_call["write", Int](Int(1), p, Int(n))


def iso_date(year: Int, md: String) raises -> String:
    """Fold a bank-statement `M/D` (or `MM/DD`, `M/D/YY`) date together with the
    statement's `year` into a sortable `"YYYY-MM-DD"` string; `""` if it isn't a
    date. Statement lines show month/day only — the year is in the header — so a
    program reads the year once, then folds each transaction's M/D with it.
    Compare/sort the results with plain `<`."""
    return _iso_date(year, md)


def parse_amount(s: String) raises -> Float64:
    """Parse a statement money string (`$4,000.00`, `1,234.56`, `-31.00`, `(42.10)`)
    into a Float64 — ignores `$`/commas/spaces/currency words, treats a leading `-`
    or surrounding `()` as negative, and returns `0.0` for a non-number. Use this
    instead of `atof` when summing amounts; `atof` crashes on the comma."""
    return _parse_amount(s)


def money(x: Float64) raises -> String:
    """Format a dollar amount as a clean string — `$31,241.06`, `-$5.00`, `$0.00`
    (rounded to cents, thousands separators). ALWAYS use this for dollar amounts in
    `print_answer`, never `String(x)` (which prints raw floats like
    `$31241.0599999998`)."""
    return _format_money(x)


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
