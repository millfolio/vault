// Workflow pane — step list with status icons, the approval gate, and
// collapsible debug detail. Mirrors web WorkflowPanel.svelte.

import SwiftUI

struct WorkflowPanel: View {
    let steps: [WorkflowStep]
    let onApprove: (String) -> Void
    let onReject: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Workflow")

            ScrollView {
                if steps.isEmpty {
                    Text("Steps, approvals, and debug detail appear here as Millfolio works.")
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(steps) { step in
                            stepCard(step)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.bg)
    }

    private func stepCard(_ step: WorkflowStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(icon(step.state))
                    .frame(width: 16)
                    .foregroundStyle(iconColor(step.state))
                Text(step.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
            }

            if let detail = step.detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, 6)
            }

            if step.state == .awaitingApproval, let approval = step.approval {
                approvalGate(step.id, approval)
            }

            ForEach(step.debug) { entry in
                DisclosureGroup {
                    CodeBlock(entry.body)
                } label: {
                    Text(entry.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
                .tint(Theme.textDim)
                .padding(.top, 8)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .top)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }

    private func approvalGate(_ stepId: String, _ approval: ApprovalPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.warn)
            CodeBlock(approval.body)
            HStack(spacing: 8) {
                Button { onApprove(stepId) } label: {
                    Text("Approve")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onOk)
                        .padding(.vertical, 6).padding(.horizontal, 14)
                        .background(Theme.ok)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                Button { onReject(stepId) } label: {
                    Text("Reject")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .padding(.vertical, 6).padding(.horizontal, 14)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.warn))
        .padding(.top, 10)
    }

    private func icon(_ state: StepState) -> String {
        switch state {
        case .pending: return "○"
        case .running: return "◐"
        case .awaitingApproval: return "⏸"
        case .done: return "●"
        case .error: return "✕"
        }
    }

    private func iconColor(_ state: StepState) -> Color {
        switch state {
        case .pending: return Theme.textDim
        case .running: return Theme.accent
        case .awaitingApproval: return Theme.warn
        case .done: return Theme.ok
        case .error: return Theme.err
        }
    }
}

/// Monospaced, bordered code/preformatted block (mirrors `pre > code`).
struct CodeBlock: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
        .padding(.top, 8)
    }
}
