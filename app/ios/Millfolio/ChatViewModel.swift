// The chat + workflow state machine — mirrors web/src/routes/+page.svelte. Owns
// the message list and the workflow steps, folds the server event stream into
// them, and drives the approval gate. Transport is chosen per-`ask`: an explicit
// server URL (persisted) uses the WebSocket client, otherwise the in-app mock.

import Foundation
import Observation

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id: String
    let role: Role
    let text: String
}

struct DebugEntry: Identifiable {
    let title: String
    let body: String
    let language: String?
    var id: String { title }
}

struct WorkflowStep: Identifiable {
    let id: String
    var label: String
    var state: StepState
    var detail: String?
    var debug: [DebugEntry] = []
    var approval: ApprovalPayload?
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var steps: [WorkflowStep] = []
    var busy = false

    /// Empty → use the in-app mock; otherwise a `ws://host:port/chat` URL.
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverKey) }
    }

    private var session: Session?
    private static let serverKey = "serverURL"

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverKey) ?? ""
    }

    var transportLabel: String {
        guard let url = wsURL else { return "Mock" }
        return url.host.map { "\($0)" } ?? "Server"
    }

    private var wsURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "ws" || url.scheme == "wss"
        else { return nil }
        return url
    }

    private func makeClient() -> MillfolioClient {
        if let url = wsURL { return WsClient(url: url) }
        return MockClient()
    }

    func send(_ text: String) {
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: text))
        steps = []
        busy = true
        session = makeClient().ask(text: text) { [weak self] event in
            self?.handle(event)
        }
    }

    func approve(_ stepId: String) {
        busy = true
        session?.approve(stepId: stepId)
    }

    func reject(_ stepId: String) {
        session?.reject(stepId: stepId, reason: "rejected by user")
    }

    // MARK: - Event folding (mirrors +page.svelte `handle`)

    private func handle(_ event: ServerEvent) {
        switch event {
        case let .status(stepId, label, state, detail):
            upsert(stepId) {
                $0.label = label
                $0.state = state
                $0.detail = detail
            }
            if state == .awaitingApproval { busy = false }  // hand control to the user
        case let .approvalRequest(stepId, _, payload):
            upsert(stepId) { $0.approval = payload }
        case let .debug(stepId, title, body, language):
            upsert(stepId) {
                $0.debug.append(DebugEntry(title: title, body: body, language: language))
            }
        case let .message(id, text):
            messages.append(ChatMessage(id: id, role: .assistant, text: text))
            busy = false
        case let .error(message):
            messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: "Error: \(message)"))
            busy = false
        }
    }

    private func upsert(_ id: String, _ patch: (inout WorkflowStep) -> Void) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            patch(&steps[i])
        } else {
            var step = WorkflowStep(id: id, label: id, state: .pending)
            patch(&step)
            steps.append(step)
        }
    }
}
