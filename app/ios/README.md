# ios (placeholder)

The Veilens iOS client — a SwiftUI app: chat on one side, the workflow/approval/
debug panel on the other. A thin client of the [protocol](../protocol), reaching
the local `server/` over Tailscale.

Not scaffolded yet. Planned: a SwiftUI app whose protocol client is generated
from `../protocol`. Note it shares **nothing** with `veilensapp/cli`'s
`VeilensCore` — that's desktop engine-lifecycle code (launchd/Process/Homebrew)
that can't run on iOS; the only shared surface is the protocol.
