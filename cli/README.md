# millfolio (CLI)

> Part of [**millfolio**](https://millfolio.app) — a private, on-device document
> vault for Apple Silicon, built on the
> [privacy_box](https://github.com/millfolio/privacy_box) privacy harness and the
> [millfolio](https://millfolio.app) inference engine.

The `millfolio` command-line tool: one binary that installs and runs the whole
vault stack on your Mac. It bootstraps the
[millfolio inference server](https://github.com/millfolio/engine) (chat +
embeddings), the privacy_box harness, and the millfolio vault — then indexes your
documents and answers questions about them locally, with the data never leaving
the machine.

`millfolio` shares its install tree (`~/Library/Application Support/Millfolio`) and
launchd-managed server (`me.millfolio.server`) with the
[`millfolio` CLI](https://github.com/millfolio/app), so the two interoperate on one
inference server; `millfolio` adds privacy_box + the vault on top.

## Install

```sh
brew install millfolio/tap/mill
```

## Use

```sh
mill install                  # millfolio server + privacy_box + millfolio site (one time, several GB)
mill index ~/vault            # embed a folder of PDFs/CSVs/Markdown on-device
mill start                    # bring it all up; opens the vault chat at http://localhost:10000
mill ask "When does my insurance renew?"   # one-shot answer over your vault
mill stop                     # shut the whole stack down
mill status                   # what's installed
```

Run `millfolio --help` for the full command list.

## Layout

| folder                            | what                                                       |
|-----------------------------------|------------------------------------------------------------|
| [`Sources/millfolio/`](Sources/millfolio)         | the `millfolio` CLI (ArgumentParser)             |
| [`Sources/MillfolioCore/`](Sources/MillfolioCore) | engine-lifecycle logic (install/start/stop)    |
| [`Sources/CZstd/`](Sources/CZstd)             | vendored zstd decoder (for the `.conda` toolchain) |
| [`dist/homebrew/`](dist/homebrew)             | the Homebrew formula + tap tooling             |

## From source (needs macOS 14+ and a Swift toolchain)

```sh
swift run millfolio --help          # run the CLI in dev
swift build -c release --product millfolio
```

The CLI is published as a signed universal binary via a Homebrew tap — see
[`dist/homebrew/`](dist/homebrew).
