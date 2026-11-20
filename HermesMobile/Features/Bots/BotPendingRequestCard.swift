import SwiftUI
import UIKit

struct BotPendingRequestCard: View {
    static let cornerRadius: CGFloat = 14

    let request: BotPendingRequest
    let identity: String
    let isEnabled: Bool
    let canStop: Bool
    let isAnswering: Bool
    let resolution: BotRequestResolution?
    let onApprove: (BotApprovalRequest.Choice) -> Void
    let onAnswer: ([BotQuestionAnswer]) -> Void
    let onSkip: () -> Void
    let onCredential: (String) -> Void
    let onStop: () -> Void
    let onConnection: (BotConnectionOperation.Answer) -> Void
    var subject: HermesRequestSubject = .bot
    var summary: ApprovalSummaryPresentation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch request {
            case .approval(let approval):
                BotApprovalRequestBody(
                    approval: approval, identity: identity, isEnabled: isEnabled,
                    isAnswering: isAnswering, onApprove: onApprove, summary: summary
                )
            case .question(let question):
                BotQuestionRequestBody(
                    question: question, identity: identity, isEnabled: isEnabled,
                    isAnswering: isAnswering, onAnswer: onAnswer, onSkip: onSkip
                )
            case .credential(let credential):
                BotCredentialRequestBody(
                    credential: credential, identity: identity, isEnabled: isEnabled,
                    isAnswering: isAnswering, onCredential: onCredential
                )
                .id(credential.requestID)
            case .desktopTask(let task):
                HermesDesktopTaskRequestBody(task: task, identity: identity, subject: subject, canStop: canStop, onStop: onStop)
            case .connection(let operation):
                HermesConnectionRequestBody(
                    operation: operation, identity: identity, subject: subject, isEnabled: isEnabled,
                    isAnswering: isAnswering, onConnection: onConnection
                )
                .id(operation.opID)
            }
            if let resolution {
                Text(resolution.message(subject))
                    .font(AppFont.caption())
                    .foregroundStyle(resolution.outcome == .answered ? Color(.appTextSecondary) : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .pendingRequestCardSurface(cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .contain)
        .onChange(of: request.requestID, initial: true) { announce() }
    }

    private func announce() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let summary: String
        switch request {
        case .approval(let approval):
            summary = approval.consequence ?? approval.command ?? String(localized: "Approval required")
        case .question(let question):
            summary = question.questions.first?.prompt ?? String(localized: "Input needed")
        case .credential(let credential):
            summary = credential.title
        case .desktopTask(let task):
            summary = task.kind.title(subject)
        case .connection:
            summary = String(localized: "Connect apps")
        }
        AccessibilityNotification.Announcement(String(localized: "Input needed: \(summary)")).post()
    }
}

private struct BotApprovalRequestBody: View {
    let approval: BotApprovalRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onApprove: (BotApprovalRequest.Choice) -> Void
    var summary: ApprovalSummaryPresentation? = nil
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault

    var body: some View {
        HermesRequestHeader(
            systemImage: "exclamationmark.triangle.fill", tint: .yellow,
            title: String(localized: "Approval required"), identity: identity
        )
        if let consequence = approval.consequence {
            Text(consequence)
                .font(AppFont.subheadline())
                .foregroundStyle(.appPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let command = approval.command {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .pendingRequestBlockSurface()
        }
        if explainsApprovals, let summary {
            ApprovalSummaryLine(presentation: summary)
        }
        if let scope = approval.scopeLine {
            Text(scope)
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { choice in
                        Button(role: choice == .deny ? .destructive : nil) {
                            onApprove(choice)
                        } label: {
                            Label(Self.title(for: choice), systemImage: Self.symbol(for: choice))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.chatDecision(Self.emphasis(for: choice)))
                        .disabled(!isEnabled || isAnswering)
                    }
                }
            }
        }
    }

    private var rows: [[BotApprovalRequest.Choice]] {
        stride(from: 0, to: approval.choices.count, by: 2).map {
            Array(approval.choices[$0..<min($0 + 2, approval.choices.count)])
        }
    }

    private static func title(for choice: BotApprovalRequest.Choice) -> String {
        switch choice {
        case .once: return String(localized: "Allow once")
        case .session: return String(localized: "Allow session")
        case .always: return String(localized: "Always allow")
        case .deny: return String(localized: "Deny")
        }
    }

    private static func symbol(for choice: BotApprovalRequest.Choice) -> String {
        switch choice {
        case .once: return "checkmark.circle.fill"
        case .session: return "lock.open"
        case .always: return "star.fill"
        case .deny: return "xmark.circle.fill"
        }
    }

    private static func emphasis(for choice: BotApprovalRequest.Choice) -> ChatDecisionButtonStyle.Emphasis {
        switch choice {
        case .once: return .primary
        case .deny: return .destructive
        default: return .secondary
        }
    }
}

private struct BotQuestionRequestBody: View {
    let question: BotQuestionRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onAnswer: ([BotQuestionAnswer]) -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var picked: [String: Set<Int>] = [:]
    @State private var typed: [String: String] = [:]

    private var submitsOnTap: Bool {
        !question.isBatch && question.questions.first?.allowsMultipleChoices == false
    }

    private var unanswered: [BotQuestionRequest.Question] { question.questions.filter { !$0.isAnswered } }

    private var canSubmit: Bool { isEnabled && !isAnswering && hasAnswer }

    private var hasAnswer: Bool {
        !unanswered.isEmpty && unanswered.allSatisfy { item in
            !(picked[item.id]?.isEmpty ?? true)
                || !(typed[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        HermesRequestHeader(
            systemImage: "questionmark.circle", tint: Color(.appTextSecondary),
            title: question.questions.count > 1
                ? String(localized: "\(question.questions.count) questions")
                : String(localized: "Clarification Required"),
            identity: question.questions.count > 1
                ? String(localized: "\(question.unansweredCount) still to answer · \(identity)")
                : identity
        )
        ForEach(question.questions) { item in
            VStack(alignment: .leading, spacing: 10) {
                Text(item.prompt)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pendingRequestBlockSurface()
                if let locked = item.lockedAnswer {
                    Label(locked, systemImage: "checkmark.circle.fill")
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .accessibilityLabel(Text("Already answered: \(locked)"))
                } else {
                    ForEach(item.choices) { choice in
                        choiceButton(choice, in: item)
                    }
                    responseField(for: item)
                }
            }
        }
        if !submitsOnTap {
            HStack(spacing: 8) {
                Button { onAnswer(answers()) } label: {
                    Label("Send answers", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.primary))
                .disabled(!canSubmit)

                Button(action: onSkip) {
                    Text("Skip").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(!isEnabled || isAnswering)
            }
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: BotQuestionRequest.Choice, in item: BotQuestionRequest.Question) -> some View {
        let isPicked = picked[item.id]?.contains(choice.id) == true
        Button {
            if submitsOnTap {
                onAnswer([BotQuestionAnswer(questionID: item.wireID, text: choice.wireLabel)])
            } else {
                toggle(choice, in: item)
            }
        } label: {
            HStack(spacing: 8) {
                if !submitsOnTap {
                    Image(systemName: selectionSymbol(isPicked: isPicked, item: item))
                        .foregroundStyle(isPicked ? Color.accentColor : Color(.appTextSecondary))
                        .accessibilityHidden(true)
                }
                Text(choice.label)
                    .font(AppFont.callout(weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if choice.isRecommended {
                    Text("Recommended")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(.appSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .foregroundStyle(.appPrimary)
            .pendingRequestChoiceSurface(reduceTransparency: reduceTransparency)
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(!isEnabled || isAnswering)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func responseField(for item: BotQuestionRequest.Question) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type a response", text: binding(for: item), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .tint(PendingRequestSubmitButton.fill(canSubmit: canSubmit, colorScheme: colorScheme))
                .pendingRequestFieldSurface()
                .disabled(!isEnabled || isAnswering)

            if submitsOnTap {
                PendingRequestSubmitButton(isBusy: isAnswering, canSubmit: canSubmit) { onAnswer(answers()) }
                    .accessibilityLabel("Send answer")
            }
        }
    }

    private func selectionSymbol(isPicked: Bool, item: BotQuestionRequest.Question) -> String {
        if item.allowsMultipleChoices { return isPicked ? "checkmark.square.fill" : "square" }
        return isPicked ? "largecircle.fill.circle" : "circle"
    }

    private func binding(for item: BotQuestionRequest.Question) -> Binding<String> {
        Binding(get: { typed[item.id] ?? "" }, set: { typed[item.id] = $0 })
    }

    private func toggle(_ choice: BotQuestionRequest.Choice, in item: BotQuestionRequest.Question) {
        var selection = picked[item.id] ?? []
        if item.allowsMultipleChoices {
            if selection.contains(choice.id) { selection.remove(choice.id) } else { selection.insert(choice.id) }
        } else {
            selection = selection.contains(choice.id) ? [] : [choice.id]
        }
        picked[item.id] = selection
    }

    private func answers() -> [BotQuestionAnswer] {
        unanswered.map { item in
            let labels = item.choices.filter { picked[item.id]?.contains($0.id) == true }.map(\.wireLabel)
            let free = (typed[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if item.allowsMultipleChoices {
                return BotQuestionAnswer(questionID: item.wireID, selections: labels + (free.isEmpty ? [] : [free]))
            }
            return BotQuestionAnswer(questionID: item.wireID, text: free.isEmpty ? (labels.first ?? "") : free)
        }
    }
}

private struct BotCredentialRequestBody: View {
    let credential: BotCredentialRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onCredential: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var value = ""

    private var canSubmit: Bool { isEnabled && !isAnswering && !value.isEmpty }

    private var canEdit: Bool { isEnabled && !isAnswering }

    var body: some View {
        HermesRequestHeader(systemImage: symbol, tint: Color(.appTextSecondary), title: credential.title, identity: identity)
        Text(credential.detail)
            .font(AppFont.subheadline())
            .foregroundStyle(.appPrimary)
            .fixedSize(horizontal: false, vertical: true)
        if let envVar = credential.envVar {
            Text(verbatim: envVar)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .pendingRequestBlockSurface()
        }
        HStack(alignment: .bottom, spacing: 10) {
            SecureField(fieldPrompt, text: $value)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(submit)
                .tint(PendingRequestSubmitButton.fill(canSubmit: canSubmit, colorScheme: colorScheme))
                .pendingRequestFieldSurface()
                .disabled(!canEdit)

            PendingRequestSubmitButton(isBusy: isAnswering, canSubmit: canSubmit, action: submit)
                .accessibilityLabel(sendLabel)
        }
        Text(credential.handling)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button { onCredential("") } label: {
            Text("Skip").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.secondary))
        .disabled(!canEdit)
        .accessibilityHint(Text(credential.kind.skipConsequence))
    }

    private var symbol: String {
        switch credential.kind {
        case .sudo: return "lock.shield.fill"
        case .secret: return "key.fill"
        }
    }

    private var fieldPrompt: LocalizedStringKey {
        switch credential.kind {
        case .sudo: return "Administrator password"
        case .secret: return "Secret value"
        }
    }

    private var sendLabel: LocalizedStringKey {
        switch credential.kind {
        case .sudo: return "Send password"
        case .secret: return "Send secret"
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let outgoing = value
        value = ""
        onCredential(outgoing)
    }
}

struct BotRequestWithdrawalNote: View {
    let withdrawal: BotRequestWithdrawal

    var body: some View {
        Label(withdrawal.message, systemImage: withdrawal.systemImage)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .onChange(of: withdrawal, initial: true) {
                guard UIAccessibility.isVoiceOverRunning else { return }
                AccessibilityNotification.Announcement(withdrawal.message).post()
            }
    }
}
