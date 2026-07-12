// Millfolio protocol — Swift mirror of ../../protocol/events.ts (the source of
// truth). Kept as a hand-written copy until the client is generated from a
// neutral schema. Keep in sync with protocol/events.ts and web/src/lib/protocol.ts.

import Foundation

/// Lifecycle of a workflow step shown in the panel.
enum StepState: String, Codable {
    case pending
    case running
    case awaitingApproval = "awaiting-approval"
    case done
    case error
}

// ── client → server ──────────────────────────────────────────────────────────
enum ClientMessage: Encodable {
    case ask(id: String, text: String)
    case approve(stepId: String)
    case reject(stepId: String, reason: String?)

    private enum CodingKeys: String, CodingKey {
        case type, id, text, stepId, reason
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ask(id, text):
            try c.encode("ask", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .approve(stepId):
            try c.encode("approve", forKey: .type)
            try c.encode(stepId, forKey: .stepId)
        case let .reject(stepId, reason):
            try c.encode("reject", forKey: .type)
            try c.encode(stepId, forKey: .stepId)
            try c.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

// ── server → client (streamed) ───────────────────────────────────────────────
/// What the user is approving — e.g. the generated program to run.
struct ApprovalPayload: Decodable, Equatable {
    let title: String
    let body: String
    let language: String?
}

enum ServerEvent: Decodable {
    case status(stepId: String, label: String, state: StepState, detail: String?)
    case approvalRequest(stepId: String, label: String, payload: ApprovalPayload)
    case debug(stepId: String, title: String, body: String, language: String?)
    case message(id: String, text: String)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type, stepId, label, state, detail, payload, title, body, language, id, text, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "status":
            self = .status(
                stepId: try c.decode(String.self, forKey: .stepId),
                label: try c.decode(String.self, forKey: .label),
                state: try c.decode(StepState.self, forKey: .state),
                detail: try c.decodeIfPresent(String.self, forKey: .detail))
        case "approval-request":
            self = .approvalRequest(
                stepId: try c.decode(String.self, forKey: .stepId),
                label: try c.decode(String.self, forKey: .label),
                payload: try c.decode(ApprovalPayload.self, forKey: .payload))
        case "debug":
            self = .debug(
                stepId: try c.decode(String.self, forKey: .stepId),
                title: try c.decode(String.self, forKey: .title),
                body: try c.decode(String.self, forKey: .body),
                language: try c.decodeIfPresent(String.self, forKey: .language))
        case "message":
            self = .message(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text))
        case "error":
            self = .error(message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown event type: \(type)")
        }
    }
}

// ── client interface (mirrors protocol.ts MillfolioClient / Session) ────────────
/// A live session: receives server events, can answer approval gates.
@MainActor
protocol Session: AnyObject {
    func approve(stepId: String)
    func reject(stepId: String, reason: String?)
}

@MainActor
protocol MillfolioClient {
    func ask(text: String, onEvent: @escaping (ServerEvent) -> Void) -> Session
}
