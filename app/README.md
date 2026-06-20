# Millfolio app

The millfolio client surface — web, iOS, and Android apps plus the local backend
server they talk to. All three apps present a **chat interface** alongside a
**workflow panel** where you watch status, approve gated steps, and debug the
interaction with the foundational model.

→ Learn more at [**millfolio.app**](https://millfolio.app).

This is a monorepo so the protocol and all three clients evolve together: change
the contract once, update the server and every client in one commit.

```
app/
├── protocol/   # the chat + workflow/approval/debug contract — source of truth
├── server/     # Mojo HTTP server (over Tailscale); wraps the privacy_box orchestrator
├── shared/     # generated TS client + design tokens shared by the web app
├── web/        # SvelteKit web app  (✅ scaffolded)
├── ios/        # SwiftUI client      (✅ scaffolded)
└── android/    # Kotlin/Compose client (placeholder)
```

## Architecture

```
web / iOS / android  ──(millfolio protocol, over Tailscale)──▶  server (Mojo)
                                                                  │
                                                                  ▼
                                                       privacy_box orchestrator
                                                       (vault codegen + sandbox)
                                                                  │
                                                                  ▼
                                                       millfolio (:8000 inference)
```

- The apps are **thin clients**: they never run the engine locally. They reach
  the Mojo `server/` over the user's tailnet (`tailscale serve`), which is the
  auth boundary — only the user's own devices can connect.
- `server/` is a thin HTTP/protocol layer that imports the **privacy_box**
  orchestrator (vault codegen loop + sandbox + egress guard) as a Mojo library,
  the same way privacy_box's current `src/server.mojo` does. Migrating that server
  in here is the first server task — see `server/README.md`.

## Develop

Web app:

```sh
cd web
npm install
npm run dev      # http://localhost:5173
```

Each platform folder is self-contained with its own toolchain; CI is
path-filtered so a change under `web/` only runs the web build, etc.
