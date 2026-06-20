# ios

The Millfolio iOS client — a SwiftUI app: chat on one side, the workflow/approval/
debug panel on the other. A thin client of the [protocol](../protocol), reaching
the local [`server/`](../server) over Tailscale. It never runs the engine
locally; the only shared surface with other clients is the protocol.

It mirrors the reference web app ([`../web`](../web)) one-to-one:

| iOS | web | role |
|---|---|---|
| `Protocol.swift` | `src/lib/protocol.ts` | the [protocol](../protocol/events.ts) types |
| `WsClient.swift` | `src/lib/wsClient.ts` | WebSocket transport (production) |
| `MockClient.swift` | `src/lib/client.ts` | no-backend workflow simulation |
| `ChatViewModel.swift` | `src/routes/+page.svelte` | event → state machine |
| `ChatPanel.swift` / `WorkflowPanel.swift` | `src/lib/components/*` | the two panels |
| `Theme.swift` | `src/app.css` | design tokens |

## Build & run

The `.xcodeproj` is **generated** from `project.yml` with
[XcodeGen](https://github.com/yonik/XcodeGen) (so the project file isn't checked
in — see `.gitignore`):

```sh
brew install xcodegen
cd ios
xcodegen generate
open Millfolio.xcodeproj      # ⌘R to run on a simulator
```

Or from the command line:

```sh
xcodebuild -project Millfolio.xcodeproj -scheme Millfolio \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Requires Xcode 16+ (built with Xcode 26 / Swift 6.3; the target is iOS 17+).

## Connecting to a server

Tap the status pill in the top bar (**Mock** by default) and enter your vault
server's WebSocket URL — e.g. `ws://100.x.y.z:10001/chat` over Tailscale. Leave
it blank to drive the UI against the in-app **mock** workflow (alias manifest →
codegen → approval gate → sandbox run → answer), which needs no backend.
