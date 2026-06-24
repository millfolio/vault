// Chat pane — message list + composer. Mirrors web ChatPanel.svelte.

import SwiftUI

struct ChatPanel: View {
    let messages: [ChatMessage]
    let busy: Bool
    let onSend: (String) -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Chat")

            ScrollViewReader { proxy in
                ScrollView {
                    if messages.isEmpty {
                        Text("Ask a question about the files in your vault")
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        .padding(16)
                    }
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            composer
        }
        .background(Theme.surface)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            Text(isUser ? "you" : "millfolio")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Theme.textDim)
            Text(message.text)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(isUser ? Theme.accentDim : Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("My question is…", text: $draft)
                .textFieldStyle(.plain)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                .foregroundStyle(Theme.text)
                .focused($composerFocused)
                .disabled(busy)
                .onSubmit(submit)

            Button(action: submit) {
                Text("Send")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .disabled(busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(busy || draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
        }
        .padding(12)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !busy else { return }
        onSend(text)
        draft = ""
    }
}

/// Shared uppercase panel header (Chat / Workflow).
struct PanelHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.66)
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }
}
