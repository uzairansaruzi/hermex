import SwiftUI
import UIKit

/// What the approval overlay shows. A webui server's approval always offers all four
/// choices; a Hermes session's offers only the ones its host computed (#1011).
struct ApprovalOverlayContent: Equatable {
    let description: String?
    let command: String?
    let scopeLine: AttributedString?
    let pendingCount: Int
    /// In the host's order: `once` first, `deny` last.
    let choices: [ApprovalChoice]
}

extension ApprovalPromptState {
    var overlayContent: ApprovalOverlayContent {
        ApprovalOverlayContent(description: pending.description, command: pending.command, scopeLine: scopeLine,
                               pendingCount: pendingCount, choices: ApprovalChoice.allCases)
    }
}

extension BotApprovalRequest {
    /// This approval in a Hermes session's overlay, one of `pendingCount` open approvals.
    func overlayContent(pendingCount: Int) -> ApprovalOverlayContent {
        ApprovalOverlayContent(description: consequence, command: command, scopeLine: scopeLine,
                               pendingCount: max(pendingCount, 1),
                               choices: choices.compactMap { ApprovalChoice(rawValue: $0.rawValue) })
    }
}

struct ApprovalRequestOverlay: View {
    let content: ApprovalOverlayContent
    let isResponding: Bool
    let errorMessage: String?
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            // Scrolls only when the card is taller than the screen (large text,
            // landscape), so every button stays reachable.
            ViewThatFits(in: .vertical) {
                card
                ScrollView {
                    card.padding(.vertical, 18)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            details
            actions
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
        .padding(.horizontal, 18)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text("Approval required")
                    .font(.headline)

                Text("Pending approvals: \(content.pendingCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = nonEmpty(content.description) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = nonEmpty(content.command) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if let scope = content.scopeLine {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if content.pendingCount > 1 {
                Text("1 of \(content.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = nonEmpty(errorMessage) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { choice in
                        approvalButton(choice)
                    }
                }
            }

            Button {
                onSkipAll()
            } label: {
                Label("Skip all this session", systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.secondary))
            .disabled(isResponding)
        }
    }

    /// Two per row in the offered order, so all four read as the familiar 2×2 and a withheld
    /// choice never moves Allow once or Deny out of reach.
    private var rows: [[ApprovalChoice]] {
        stride(from: 0, to: content.choices.count, by: 2).map {
            Array(content.choices[$0..<min($0 + 2, content.choices.count)])
        }
    }

    private func approvalButton(_ choice: ApprovalChoice) -> some View {
        Button(role: choice == .deny ? .destructive : nil) {
            onChoice(choice)
        } label: {
            Label(Self.title(for: choice), systemImage: Self.symbol(for: choice))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(Self.emphasis(for: choice)))
        .disabled(isResponding)
    }

    private static func title(for choice: ApprovalChoice) -> LocalizedStringKey {
        switch choice {
        case .once: return "Allow once"
        case .session: return "Allow session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    private static func symbol(for choice: ApprovalChoice) -> String {
        switch choice {
        case .once: return "checkmark.circle.fill"
        case .session: return "lock.open"
        case .always: return "star.fill"
        case .deny: return "xmark.circle.fill"
        }
    }

    private static func emphasis(for choice: ApprovalChoice) -> ChatDecisionButtonStyle.Emphasis {
        switch choice {
        case .once: return .primary
        case .session, .always: return .secondary
        case .deny: return .destructive
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension ApprovalRequestOverlay {
    /// A webui server's pending approval.
    init(prompt: ApprovalPromptState, isResponding: Bool, errorMessage: String?,
         onChoice: @escaping (ApprovalChoice) -> Void, onSkipAll: @escaping () -> Void) {
        self.init(content: prompt.overlayContent, isResponding: isResponding, errorMessage: errorMessage,
                  onChoice: onChoice, onSkipAll: onSkipAll)
    }
}

struct ApprovalBypassStatusPill: View {
    /// Turns the bypass off, on a Hermes session (#1011). Nil where the pill only reports it.
    var onTurnOff: (() -> Void)?

    var body: some View {
        if let onTurnOff {
            Button(action: onTurnOff) {
                pill(showsTurnOff: true)
            }
            .buttonStyle(.chatTactile(.capsule))
        } else {
            pill(showsTurnOff: false)
        }
    }

    private func pill(showsTurnOff: Bool) -> some View {
        HStack(spacing: 8) {
            Label("Approval bypass active", systemImage: "bolt.slash.fill")
            if showsTurnOff {
                Text("Turn off")
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }
}
