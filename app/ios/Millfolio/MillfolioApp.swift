// Millfolio iOS — a thin client of the Millfolio protocol (see ../../protocol). Chat
// on one side, the workflow/approval/debug panel on the other; it never runs the
// engine locally, only talks to the user's own `server/` over Tailscale.

import SwiftUI

@main
struct MillfolioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
