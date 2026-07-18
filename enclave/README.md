# enclave

\*\*A privacy harness: use a frontier model to write code that runs on private
data locally — the data never leaves the machine.\*\*

> Part of [**millfolio.app**](https://millfolio.app) using
> [**millfolio**](https://millfolio.app) — local-first AI on Apple Silicon.
> **Experimental.**

A _enclave_ is the gate at the intake of a millfolio that controls how much
water enters the channel. This project is the controlled intake on the channel
that drives the mill: it lets a powerful remote model do the thinking, while
keeping your private data on your side of the gate.

## Approach

You have private/local data and a small, capable **local model** (served by
[`millfolio`](https://github.com/millfolio/engine), the pure-Mojo local LLM
engine). The local model is good enough to reason over your data, but some tasks
need a frontier model's code-generation ability.

Rather than ship the data to the frontier model, enclave flips the
relationship: **the remote model is treated as an untrusted code generator, not
a data processor.** It sees only the _shape_ of your data (a sanitized schema)
and writes code. That code runs **locally**, in a sandbox, against the real
data. Results stay local. The data never crosses the gate.

## Two execution roles

| role             | executes                                              | who                             |
| ---------------- | ----------------------------------------------------- | ------------------------------- |
| **model runner** | the local _model_ (inference)                         | `millfolio` OpenAI API           |
| **code runner**  | the remote model's generated _code_ over private data | the **sandbox inside enclave** |

`millfolio` stays harness-agnostic: it is just an OpenAI-compatible inference
server. The seam between it and enclave is the OpenAI API, so anyone can run
`millfolio` under a harness of their choice, or point enclave at a different
local engine.

## Threat model: the careful SaaS provider

enclave v1 defends against an **honest-but-careless** remote provider — one
that won't deliberately smuggle data out, but whose generated code might
_accidentally_ leak it (e.g. a stray `requests.post` to a telemetry endpoint, or
a stack trace that echoes a private value back into the next prompt).

That model lets us skip the expensive paranoia (covert timing/size channels,
human-in-the-loop on every byte) and concentrate everything on two chokepoints:

1. **A sandbox that can't phone home** — network denied, read-only scoped
   filesystem, resource limits, a tiny capability allowlist.
2. **An egress guard** — every payload bound for the remote model passes through
   one filter that redacts and _tripwires_ on real-data fingerprints (and canary
   tokens seeded into the real data only).

Out of scope for v1: a genuinely adversarial provider trying to exfiltrate
through covert channels. That's a later, harder threat model.

## Two guarantees

- **Containment** (owned by the sandbox): generated code cannot reach the
  network or escape its scope; its output is captured, never self-emitted.
- **Confidentiality** (owned by enclave): nothing sent to the remote model
  contains real data — enforced by schema sanitization + the egress guard, and
  by debugging against _synthetic_ data shaped like the real schema, with the
  real data touched only on a final run whose raw output never loops back.

## Design principles

- **Mechanism vs. policy.** `inference-server` (local inference) and the sandbox
  (containment) are mechanism. enclave is confidentiality _policy_ on top.
- **Code is the interface** between the capable-but-untrusted party and the
  private party — not data.
- **Sanitize the schema, not just the values.** Column/table names can leak on
  their own; enclave aliases them, mapping real names back locally.
- **No silent leaks.** The egress guard fails closed; any real-data span or
  canary on the outbound path blocks the send.

## Components

- **harness** — owns user intent and data handles; drives the
  synthetic-debug → real-run loop; decides what (if anything) returns to remote.
- **remote codegen client** — talks to the frontier model (Claude API); sends
  spec + sanitized schema + synthetic samples; receives code + a capability
  manifest.
- **schema sanitizer** — derives the schema, aliases sensitive names, and
  synthesizes fake sample rows that match it.
- **egress guard** — the single outbound chokepoint: fingerprint tripwire +
  canary detection + PII redaction; fails closed.
- **code sandbox** — executes generated code under a deny-network policy with a
  small capability broker; captures results/logs locally.

## Layout

```
README.md / PRIOR-ART.md / SPIKE.md   design intent · prior-art survey · sandbox spike
DOCUMENT-MODE.md                      design: arbitrary files (PDF/docx/…), not just CSV
pixi.toml                             Mojo nightly + flare/jinja2.mojo wiring; `pixi run spike`
sandbox/enclave.sb.template          PROVEN Seatbelt confinement profile
sandbox/spike.sh                      6/6-passing containment proof (no toolchain needed)
src/egress.mojo                       EgressGuard — outbound confidentiality chokepoint
src/vaultcfg.mojo                     millfolio vault paths (manifest bin, -I set, index dir)
src/transport.mojo                    Local/Remote clients (remote gated by EgressGuard)
src/sandbox.mojo + src/broker.mojo    containment runner + capability allowlist
src/harness.mojo                 core loop: aliased manifest → codegen → loopback run
src/enclave.mojo + src/server.mojo   composition root: CLI vault harness + HTTP server
web/                                  enclave for the web — local React chat UI
```

## Configuration

enclave reads `~/.config/enclave/config.json` (override the path with
`ENCLAVE_CONFIG`). It's parsed with the `json` fork (`src/settings.mojo`). All
keys are optional; see [`config.example.json`](config.example.json):

| key                   | default                        | env override                                      |
| --------------------- | ------------------------------ | ------------------------------------------------- |
| `local_url`           | `http://127.0.0.1:8000/v1`     | `ENCLAVE_LOCAL_URL`                              |
| `local_model`         | `local`                        | `ENCLAVE_LOCAL_MODEL`                            |
| `remote_base_url`     | `https://api.anthropic.com/v1` | `ANTHROPIC_BASE_URL`                              |
| `remote_model`        | `claude-sonnet-5`            | `ENCLAVE_MODEL`                                  |
| `remote_token_budget` | `-1` (unlimited)               | `ENCLAVE_REMOTE_TOKEN_BUDGET`                    |
| `anthropic_api_key`   | `""`                           | `ANTHROPIC_API_KEY` _(env preferred for secrets)_ |
| `mock`                | `false`                        | `ENCLAVE_MOCK` (set = true)                      |
| `use_local_summary`   | `false`                        | `ENCLAVE_LOCAL` (set = true)                     |

**Precedence: environment variable > config file > built-in default** — so
existing env-based workflows are unchanged, and the file is just a default
layer.
