// Real Millfolio client over WebSocket — the production transport (see
// ../../server/STREAMING.md). One WS connection per session: send `ask`, receive
// a stream of ServerEvents, answer any `approval-request` with `approve`/`reject`
// on the same socket. Same MillfolioClient interface as the mock, so the UI is
// identical either way. Mirrors web/src/lib/wsClient.ts.

import Foundation

@MainActor
final class WsSession: Session {
    private let task: URLSessionWebSocketTask
    private let url: URL
    private let onEvent: (ServerEvent) -> Void
    private let encoder = JSONEncoder()
    private var closed = false

    init(url: URL, text: String, onEvent: @escaping (ServerEvent) -> Void) {
        self.url = url
        self.onEvent = onEvent
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        receive()
        // URLSessionWebSocketTask queues sends until the socket is open, so we can
        // emit `ask` immediately (the web client buffers manually for the same effect).
        write(.ask(id: UUID().uuidString, text: text))
    }

    func approve(stepId: String) { write(.approve(stepId: stepId)) }
    func reject(stepId: String, reason: String?) { write(.reject(stepId: stepId, reason: reason)) }

    private func write(_ m: ClientMessage) {
        guard
            let data = try? encoder.encode(m),
            let json = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(json)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.fail("cannot reach server at \(self?.url.absoluteString ?? "")")
            }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch result {
                case .failure:
                    self.fail("connection to \(self.url.absoluteString) closed")
                case .success(let message):
                    self.handle(message)
                    self.receive()  // keep reading until the server closes the socket
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let data = text?.data(using: .utf8) else { return }
        if let event = try? JSONDecoder().decode(ServerEvent.self, from: data) {
            onEvent(event)
        } else {
            onEvent(.error(message: "malformed event from server"))
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        closed = true
        onEvent(.error(message: message))
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
    }
}

@MainActor
struct WsClient: MillfolioClient {
    let url: URL

    func ask(text: String, onEvent: @escaping (ServerEvent) -> Void) -> Session {
        WsSession(url: url, text: text, onEvent: onEvent)
    }
}
