# shared

Cross-client shared assets:

- **Generated protocol client** — once `../protocol` is formalized into a neutral
  schema, the TypeScript client (for `../web`) is generated here and imported by
  the web app. (Swift/Kotlin clients are generated into `../ios` / `../android`.)
- **Design tokens** — the Veilens palette/spacing/type scale, so the web app and
  the native apps stay visually consistent.

Placeholder for now; the web app currently carries its own copy of the protocol
types and tokens (`web/src/lib/protocol.ts`, `web/src/app.css`).
