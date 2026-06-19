# vault

The millfolio personal data vault — index your own PDFs, CSVs, and Markdown and
ask open-ended questions, answered **locally**. A frontier model writes the code
that runs on your data; the data never leaves the machine.

This repo consolidates what used to be three separate repos
(`veilens` + `headgate` + `cli`) into one. History was intentionally not
preserved.

## Layout

| dir | was | language | what it does |
|---|---|---|---|
| **`core/`** | veilens | Mojo | the vault: indexer, embeddings, the tool surface a sandboxed program imports, the ask loop |
| **`sandbox/`** | headgate | Mojo | the privacy harness: brokers between the local engine and a frontier model, sandboxes generated code, enforces egress |
| **`cli/`** | cli | Swift | the `vault` umbrella command — `install` / `start` / `stop` / `index` / `ask`; provisions the engine + sandbox + vault |

## Dependencies (separate repos in the `millfolio` org)

- **Libraries**, consumed via `-I`: `flare`, `json`, `lancedb.mojo`,
  `pdftotext.mojo`, `zlib.mojo`, `csv.mojo`, `jinja2.mojo`. Checked out as
  siblings of this repo.
- **Engine** (`millfolio/engine`): the local inference server, used as the
  embedding/local-model server. Not built here — **vendored as a prebuilt
  binary** into the install bundle.

## Install shape (target)

One Mojo source (this repo) + **one zip** that vendors the built engine binary,
the compiled lib FFI shims (flare TLS/HTTP, zlib, lancedb), and assets. Frontier
access is just an `ANTHROPIC_API_KEY` the user supplies — nothing to install.

## Build

One `pixi.toml` at the repo root builds both Mojo binaries — the "one mojo":

```sh
pixi run build      # -> build/vault (core) + build/sandbox (headgate)
pixi run vault      # just the vault binary
pixi run sandbox    # just the privacy harness
pixi run cli        # the Swift umbrella CLI (separate toolchain)
```

The libraries are sibling repos under `~/dev/millfolio/` (flare, json,
lancedb.mojo, pdftotext.mojo, zlib.mojo, csv.mojo, jinja2.mojo), consumed via
`-I ../lib`. The `ffi` task (a `build` dependency) compiles the FFI shims
(flare TLS/HTTP, zlib, the lancedb Rust cdylib) into the env. `core` and
`sandbox` are independent binaries — they cooperate at runtime (the harness runs
the vault binary sandboxed), not via Mojo imports.
