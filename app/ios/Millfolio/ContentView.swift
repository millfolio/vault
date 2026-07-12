// Root screen — brand bar over the two panels. Mirrors web routes/+page.svelte:
// chat and workflow side by side on a wide screen (iPad / landscape), stacked
// vertically on a phone (compact width), exactly like the web's responsive grid.

import SwiftUI

struct ContentView: View {
    @State private var model = ChatViewModel()
    @State private var vaultModel = VaultViewModel()
    @State private var tab = 0
    @State private var showSettings = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            brandBar
            Picker("View", selection: $tab) {
                Text("Chat").tag(0)
                Text("Vault").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)

            if tab == 0 {
                panes
            } else {
                VaultView(model: vaultModel)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(serverURL: $model.serverURL)
        }
    }

    private var brandBar: some View {
        HStack {
            Text("millfolio")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.transportLabel == "Mock" ? Theme.textDim : Theme.ok)
                        .frame(width: 7, height: 7)
                    Text(model.transportLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom)
    }

    @ViewBuilder
    private var panes: some View {
        let chat = ChatPanel(messages: model.messages, busy: model.busy, onSend: model.send)
        let workflow = WorkflowPanel(steps: model.steps, onApprove: model.approve, onReject: model.reject)

        if sizeClass == .regular {
            HStack(spacing: 0) {
                chat
                workflow.overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.border), alignment: .leading)
            }
        } else {
            VStack(spacing: 0) {
                chat
                workflow.overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
            }
        }
    }
}

/// Connection settings — the `ws://host:port/chat` server URL (blank = mock).
struct SettingsSheet: View {
    @Binding var serverURL: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://100.x.y.z:10000/chat", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 14, design: .monospaced))
                } header: {
                    Text("Vault server")
                } footer: {
                    Text("Your vault app server over Tailscale (one port — chat, vault, and search). "
                         + "Use wss:// for the Tailscale HTTPS name. Leave blank for the in-app mock.")
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ContentView()
}
