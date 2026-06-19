# veilens

> Part of [**veilens.app**](https://veilens.app) using
> [**millrace**](https://millrace.app) — local-first AI on Apple Silicon.
> **Experimental.**

Ask open-ended questions about your own files — _"how much did I spend on travel
last year?"_, _"when do I renew my insurance?"_, _"what's the license plate of
my car?"_ — over a private vault of **CSV, PDF, and Markdown** documents,
**without your data ever leaving the machine**.

veilens is the **vault application**. It builds on the
[privacy_box](https://github.com/millrace/privacy_box) privacy harness and the
millrace toolbox: [lancedb.mojo](https://github.com/millrace/lancedb.mojo) for
the on-device vector index,
[pdftotext.mojo](https://github.com/millrace/pdftotext.mojo) for PDF extraction,
and the local [inference server](https://github.com/millrace/millrace) as the
trusted on-device reader.

## How the privacy model works

There are **two models**, deliberately asymmetric:

- A **frontier model** (untrusted) is the _planner/coder_. It answers your
  question by writing **one Mojo program** that calls a fixed set of vault
  **tools**. It sees only a **sanitized manifest** — file _aliases_ (`file_0`),
  kinds, and aliased column schemas (`col_2`) — never the contents, names, or
  paths. The program's results never return to it.
- A **local model** (trusted, on your device) is the _reader_. When the program
  needs to understand content — "is this a travel expense?", "extract the
  renewal date" — it calls `ask_local(instruction, content)`, which runs on the
  inference server and sees the real text.

So the frontier model orchestrates over aliases; the local model reads; the data
and the final answer stay on the machine. This is enforced by privacy_box's egress
guard and a network-denied sandbox — the generated program runs locally and can
only reach the local model.

## The vault tools

The generated program does `from vault import *` and has:

| tool                              | purpose                                                            |
| --------------------------------- | ------------------------------------------------------------------ |
| `manifest()`                      | the aliased file list (`.alias`, `.kind`, `.size`, csv `.columns`) |
| `search(query, k)`                | semantic search across the indexed vault → ranked chunks           |
| `csv_rows(alias)`                 | a table's rows, columns by alias                                   |
| `pdf_text(alias)`                 | extracted text of a PDF (via pdftotext.mojo)                       |
| `md_text(alias)`                  | a markdown file's text                                             |
| `ask_local(instruction, content)` | the trusted on-device reader                                       |
| `print_answer(s)`                 | emit the final answer (local only)                                 |

## Pipeline

```
your files ─▶ index: chunk + embed (local) ─▶ LanceDB vector store
                                                      │
question ─▶ privacy_box: frontier writes a vault program │ (sees only aliases)
                          │                           ▼
                          └─▶ sandbox run ─▶ search / read / ask_local ─▶ answer (local)
```

## Status

Vault data plane is wired: the **manifest** (confidentiality boundary), the
three **readers** (CSV/PDF/Markdown), the **embedding client** + **LanceDB
indexer/search**, and the **`vault` tool library** that privacy_box-generated
programs import. Still to come: the privacy_box-driven `ask` loop on top.

What's verified vs. pending a live server:

- ✅ readers, manifest, chunking, LanceDB wiring, and the `vault` tool surface
  all compile and run (PDF text extraction verified on a real PDF).
- ⏳ `embed`, `index`, and `search` need the local **inference-server**
  embeddings endpoint (`/v1/embeddings`, Qwen3-Embedding-0.6B, dim 1024) live;
  until then they fail with a clear "endpoint not serving" message. `ask_local`
  likewise needs the local chat-completions endpoint.

## Use

```sh
pixi run ffi                              # build the native shims (zlib/flare/lancedb)
pixi run build                            # compile the veilens CLI (runs ffi first)

veilens manifest <vault-dir>              # aliased manifest (frontier-visible view)
veilens read <file_N> <vault-dir>         # smoke-test a reader (csv/pdf/md preview)
veilens embed "<text>"                    # smoke-test the embedding client*
veilens index <vault-dir>                 # chunk+embed the vault into LanceDB*
veilens search "<query>" [k]              # semantic search over the index*

#  * needs the local inference-server running (embeddings/chat endpoints)
```

The index lives under `~/.config/veilens/` (`index.db` + `chunks.tsv`
side-table). Local model URLs are configurable via `VEILENS_LOCAL_URL` (default
`http://127.0.0.1:8000/v1`) and `VEILENS_VAULT` (default `~/.config/veilens/vault`).

There are also `pixi run smoke-readers` / `smoke-embed` / `smoke-index` /
`build-vault` tasks that exercise each layer against a throwaway vault.
