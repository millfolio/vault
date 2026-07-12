// Mock Millfolio client — drives the UI without a backend yet. It simulates the
// server streaming the vault workflow (alias manifest → ask model → approval gate
// → compile → run → answer), including a debug payload per step and one approval
// gate. Swap for WsClient (the same MillfolioClient interface) to talk to the real
// Mojo `server/` over Tailscale. Mirrors web/src/lib/client.ts.

import Foundation

private let sampleProgram = """
from vault import *

def main():
    # aliased columns only — never the real data
    rows = search("oldest transaction", k=5)
    print(rows.min_by("date_col_0"))
"""

@MainActor
final class MockSession: Session {
    private let text: String
    private let onEvent: (ServerEvent) -> Void
    private var gate: CheckedContinuation<(ok: Bool, reason: String?), Never>?
    private var seq = 0

    init(text: String, onEvent: @escaping (ServerEvent) -> Void) {
        self.text = text
        self.onEvent = onEvent
        Task { await run() }
    }

    func approve(stepId: String) {
        gate?.resume(returning: (true, nil))
        gate = nil
    }

    func reject(stepId: String, reason: String?) {
        gate?.resume(returning: (false, reason))
        gate = nil
    }

    private func uid(_ prefix: String) -> String {
        seq += 1
        return "\(prefix)-\(seq)"
    }

    private func wait(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func awaitGate() async -> (ok: Bool, reason: String?) {
        await withCheckedContinuation { continuation in
            gate = continuation
        }
    }

    private func run() async {
        let manifest = uid("manifest")
        onEvent(.status(stepId: manifest, label: "Aliasing vault manifest", state: .running, detail: nil))
        await wait(600)
        onEvent(.debug(
            stepId: manifest,
            title: "Frontier-safe manifest (aliases only)",
            body: "file_0  col_0:date  col_1:amount  col_2:merchant\nfile_1  col_0:date  col_1:balance",
            language: "text"))
        onEvent(.status(stepId: manifest, label: "Aliasing vault manifest", state: .done, detail: nil))

        let gen = uid("codegen")
        onEvent(.status(stepId: gen, label: "Asking the model to write a program", state: .running, detail: nil))
        await wait(800)
        onEvent(.debug(stepId: gen, title: "Generated program", body: sampleProgram, language: "mojo"))
        onEvent(.status(stepId: gen, label: "Asking the model to write a program", state: .done, detail: nil))

        // Approval gate.
        let run = uid("run")
        let label = "Run the generated program over your vault?"
        onEvent(.status(stepId: run, label: label, state: .awaitingApproval, detail: nil))
        onEvent(.approvalRequest(
            stepId: run,
            label: label,
            payload: ApprovalPayload(
                title: "Sandboxed run — reads your real data locally, no network",
                body: sampleProgram,
                language: "mojo")))

        let decision = await awaitGate()
        guard decision.ok else {
            onEvent(.status(stepId: run, label: "Run rejected", state: .error, detail: decision.reason))
            onEvent(.message(
                id: uid("msg"),
                text: "Okay — I won't run that. Tell me how you'd like to adjust it."))
            return
        }

        onEvent(.status(stepId: run, label: "Compiling & running in sandbox", state: .running, detail: nil))
        await wait(900)
        onEvent(.debug(stepId: run, title: "Sandbox stdout", body: "2024-01-03  -42.10  Corner Market", language: "text"))
        onEvent(.status(stepId: run, label: "Compiling & running in sandbox", state: .done, detail: nil))

        onEvent(.message(
            id: uid("msg"),
            text: "Your oldest transaction is from 2024-01-03: $42.10 at Corner Market. (Asked: \"\(text)\")"))
    }
}

@MainActor
struct MockClient: MillfolioClient {
    func ask(text: String, onEvent: @escaping (ServerEvent) -> Void) -> Session {
        MockSession(text: text, onEvent: onEvent)
    }
}
