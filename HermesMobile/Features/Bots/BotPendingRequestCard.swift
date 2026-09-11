import SwiftUI
import UIKit

/// The request blocking a bot, rendered in the transcript where its work
/// stopped, so the command sits under the tool row that asked for it.
///
/// Placement is the only thing Bot-specific here: the surfaces, choice buttons,
/// decision buttons and copy are the Sessions approval and clarification
/// vocabulary. `isEnabled` false is a resolved, expired or in-flight request:
/// the card stays readable and stops acting.
///
/// Only the Desktop-task body has no input, because its answer is data the
/// Desktop renderer holds. Everything else — approvals, questions, sudo and
/// secret prompts — is answered from here.
struct BotPendingRequestCard: View {
    static let cornerRadius: CGFloat = 14

    let request: BotPendingRequest
    /// Which bot on which connection is asking, so two hosts with equal Profile
    /// names never produce an anonymous card.
    let identity: String
    let isEnabled: Bool
    /// Stop is gated separately: a Desktop-only request is never answerable, but
    /// stopping the work it blocks is exactly what the phone still owns.
    let canStop: Bool
    let isAnswering: Bool
    let resolution: BotRequestResolution?
    let onApprove: (BotApprovalRequest.Choice) -> Void
    let onAnswer: ([BotQuestionAnswer]) -> Void
    let onSkip: () -> Void
    /// Sends a typed sudo password or secret. Empty is the host's skip.
    let onCredential: (String) -> Void
    /// Calls off a Desktop task that can be declined. Only `mcp.setup` can.
    let canDecline: Bool
    let onDecline: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch request {
            case .approval(let approval):
                BotApprovalRequestBody(
                    approval: approval, identity: identity, isEnabled: isEnabled,
                    isAnswering: isAnswering, onApprove: onApprove
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
            case .desktopTask(let task):
                BotDesktopTaskRequestBody(
                    task: task, identity: identity, canStop: canStop,
                    canDecline: canDecline, onDecline: onDecline, onStop: onStop
                )
            }
            if let resolution {
                Text(resolution.message)
                    .font(.caption)
                    .foregroundStyle(resolution.outcome == .answered ? .secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .pendingRequestCardSurface(cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .contain)
        .onChange(of: request.requestID, initial: true) { announce() }
    }

    /// One announcement per request; re-renders and answers stay silent.
    private func announce() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let summary: String
        switch request {
        case .approval(let approval):
            summary = approval.consequence ?? approval.command ?? String(localized: "Approval required")
        case .question(let question):
            summary = question.questions.first?.prompt ?? String(localized: "Input needed")
        case .credential(let credential):
            summary = credential.kind.title
        case .desktopTask(let task):
            summary = task.kind.title
        }
        AccessibilityNotification.Announcement(String(localized: "Input needed: \(summary)")).post()
    }
}

/// A command approval. Only the choices the host actually offered are shown:
/// a smart-denied or permanent-allow-blocked request legitimately has fewer.
private struct BotApprovalRequestBody: View {
    let approval: BotApprovalRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onApprove: (BotApprovalRequest.Choice) -> Void

    var body: some View {
        BotRequestHeader(
            systemImage: "exclamationmark.triangle.fill", tint: .yellow,
            title: String(localized: "Approval required"), identity: identity
        )
        if let consequence = approval.consequence {
            Text(consequence)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let command = approval.command {
            // Horizontally scrollable and selectable, so a long command is
            // readable in full before it is approved.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .pendingRequestBlockSurface()
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

    /// Two per row, in the host's order, so Allow once and Deny stay reachable
    /// without the layout changing when a choice is withheld.
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

/// One or many clarify questions. A single single-select question submits on
/// tap, as the Sessions card does; multi-select and batches need a deliberate
/// Send because no one tap can express the whole answer.
private struct BotQuestionRequestBody: View {
    let question: BotQuestionRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onAnswer: ([BotQuestionAnswer]) -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    /// Choice ids picked per question id, and the free text typed for it.
    @State private var picked: [String: Set<Int>] = [:]
    @State private var typed: [String: String] = [:]

    /// True when one tap is the whole answer, so no Send control is needed.
    private var submitsOnTap: Bool {
        !question.isBatch && question.questions.first?.allowsMultipleChoices == false
    }

    private var unanswered: [BotQuestionRequest.Question] { question.questions.filter { !$0.isAnswered } }

    private var canSubmit: Bool { isEnabled && !isAnswering && hasAnswer }

    /// Every outstanding question, not just one. A partial send would lock the
    /// untouched questions as skipped, so Send waits for the whole batch and
    /// Skip stays the deliberate way to decline all of it.
    private var hasAnswer: Bool {
        !unanswered.isEmpty && unanswered.allSatisfy { item in
            !(picked[item.id]?.isEmpty ?? true)
                || !(typed[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        BotRequestHeader(
            systemImage: "questionmark.circle", tint: .secondary,
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
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pendingRequestBlockSurface()
                if let locked = item.lockedAnswer {
                    Label(locked, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                }
                Text(choice.label)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if choice.isRecommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .foregroundStyle(.primary)
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

            // A batch or multi-select answer is sent by the Send control below,
            // which speaks for every question at once.
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

    /// One answer per question the host has not already locked. A blank one is a
    /// deliberate skip for that question, which is what the host's tool reads it as.
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

/// A sudo password or a secret the bot asked for. Masked, sent straight to the
/// host and never held on the model, in a draft or anywhere else on the phone.
/// Skip is a first-class answer: it releases the bot immediately instead of
/// leaving it parked until the host's deadline.
private struct BotCredentialRequestBody: View {
    let credential: BotCredentialRequest
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onCredential: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var value = ""

    private var canSubmit: Bool { isEnabled && !isAnswering && !value.isEmpty }

    var body: some View {
        BotRequestHeader(
            systemImage: credential.kind == .sudo ? "lock.shield.fill" : "key.fill",
            tint: .secondary, title: credential.kind.title, identity: identity
        )
        Text(credential.detail)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        if let envVar = credential.envVar {
            // The name the host will store it under, so the user knows which of
            // their keys to paste before they paste one.
            Text(envVar)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .pendingRequestBlockSurface()
        }
        HStack(alignment: .bottom, spacing: 10) {
            SecureField(credential.kind == .sudo ? "Administrator password" : "Secret value", text: $value)
                .textContentType(credential.kind == .sudo ? .password : nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(submit)
                .tint(PendingRequestSubmitButton.fill(canSubmit: canSubmit, colorScheme: colorScheme))
                .pendingRequestFieldSurface()
                .disabled(!isEnabled || isAnswering)

            PendingRequestSubmitButton(isBusy: isAnswering, canSubmit: canSubmit, action: submit)
                .accessibilityLabel(credential.kind == .sudo ? "Send password" : "Send secret")
        }
        Text(credential.handling)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button { onCredential("") } label: {
            Text("Skip").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.secondary))
        .disabled(!isEnabled || isAnswering)
        .accessibilityHint(Text(credential.kind.skipConsequence))
    }

    private func submit() {
        guard canSubmit else { return }
        let outgoing = value
        // Dropped from the view the moment it is handed over; the model never
        // holds it either, so no layer of the phone keeps the value around.
        value = ""
        onCredential(outgoing)
    }
}

/// Work the Desktop renderer does and answers itself. There is no input because
/// there is no answer a person gives — not here, and not at the Mac either. The
/// host releases the bot on its own deadline, so the card reports the wait and
/// keeps Stop for the user who does not want to wait it out.
private struct BotDesktopTaskRequestBody: View {
    let task: BotDesktopTaskRequest
    let identity: String
    let canStop: Bool
    let canDecline: Bool
    let onDecline: () -> Void
    let onStop: () -> Void

    var body: some View {
        BotRequestHeader(
            systemImage: "desktopcomputer", tint: .secondary,
            title: task.kind.needsSomeoneAtTheMac
                ? String(localized: "Waiting on Hermes Desktop")
                : String(localized: "Hermes Desktop is handling this"),
            identity: identity
        )
        Text(task.kind.title)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        Text(task.kind.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // Declining beats stopping where it is offered: it calls off this one
        // request and lets the bot finish its work, where Stop ends the work.
        if task.kind.isDeclinable {
            Button(action: onDecline) {
                Text("Skip this setup").frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.secondary))
            .disabled(!canDecline)
        }
        Button(role: .destructive, action: onStop) {
            Label("Stop current work", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.destructive))
        .disabled(!canStop)
    }
}

private struct BotRequestHeader: View {
    let systemImage: String
    let tint: Color
    let title: String
    let identity: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(identity).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }
}
