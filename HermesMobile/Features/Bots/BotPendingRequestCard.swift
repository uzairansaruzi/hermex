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
/// Only the Desktop-task body has no input, because its answer is data or a
/// password only Hermes Desktop holds. Everything else — approvals, questions,
/// sudo and secret prompts, connection operations — is answered from here.
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
    /// Skips a Desktop task that waits for a person at the Mac (`vault.*`).
    let canDecline: Bool
    let onDecline: () -> Void
    let onStop: () -> Void
    /// One row's answer, or Continue, for a connection operation.
    let onConnection: (BotConnectionOperation.Answer) -> Void

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
                // A new request gets a fresh, empty field: a password typed for a
                // timed-out sudo prompt must never ride along into a secret.
                .id(credential.requestID)
            case .desktopTask(let task):
                BotDesktopTaskRequestBody(
                    task: task, identity: identity, canStop: canStop,
                    canDecline: canDecline, onDecline: onDecline, onStop: onStop
                )
            case .connection(let operation):
                BotConnectionRequestBody(
                    operation: operation, identity: identity, isEnabled: isEnabled,
                    isAnswering: isAnswering, onConnection: onConnection
                )
                // Typed setup values belong to one operation's rows.
                .id(operation.opID)
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
        case .connection:
            summary = String(localized: "Connect apps")
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
/// The field offers Password AutoFill, so a saved key can fill it, and its
/// value belongs to one request: the card keys this body by request id, so a
/// replacement request starts empty. Skip is a first-class answer: it releases
/// the bot immediately instead of leaving it parked until the host's deadline.
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
                .textContentType(.password)
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

/// A request only Hermes Desktop answers. Most are work its renderer does by
/// itself, with no answer a person gives; the host releases the bot on its own
/// deadline, so the card reports the wait and keeps Stop for the user who does
/// not want to wait it out. A password-manager prompt waits for someone at the
/// Mac, so its card also offers Skip.
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
        // Skipping beats stopping where it is offered: it calls off this one
        // request and lets the bot finish its work, where Stop ends the work.
        if task.kind.needsSomeoneAtTheMac {
            Button(action: onDecline) {
                Text("Skip").frame(maxWidth: .infinity)
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

/// A `manage_connections` operation: one row per app, in the host's order, each
/// with only the moves the host allows for its kind and state. Continue without
/// is the one control that releases the bot whatever the rows say, so it stays
/// until the settled frame removes the card. The deadline is the host's, shown
/// in whole minutes and redrawn once a minute, never animated.
private struct BotConnectionRequestBody: View {
    let operation: BotConnectionOperation
    let identity: String
    let isEnabled: Bool
    let isAnswering: Bool
    let onConnection: (BotConnectionOperation.Answer) -> Void

    var body: some View {
        BotRequestHeader(systemImage: "link", tint: .secondary, title: String(localized: "Connect apps"), identity: identity)
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.everyMinute) { context in
                let minutes = BotConnectionOperation.minutesLeft(until: operation.deadline, now: context.date)
                // The system's own unit wording, so every language gets its plural right.
                let left = Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
                Text("Waiting · \(left) left")
                    .font(.subheadline.weight(.semibold))
            }
            Text("The bot is paused until each app is connected or skipped.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(operation.targets) { target in
            BotConnectionTargetRow(target: target, isEnabled: isEnabled, isAnswering: isAnswering,
                                   onConnection: onConnection)
        }
        Button { onConnection(.continueWithout) } label: {
            Text("Continue without").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.secondary))
        .disabled(!isEnabled || isAnswering)
        Text("Releases the bot now. Apps not connected stay off for this reply.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One app in a connection operation. A managed connector opens its sign-in in
/// the browser; an MCP enable or install connects here with a field per value it
/// still needs; an MCP sign-in only finishes at the Mac. Setup values live in
/// this row's state alone, are masked when secret, and are dropped the moment
/// they are handed over.
private struct BotConnectionTargetRow: View {
    let target: BotConnectionOperation.Target
    let isEnabled: Bool
    let isAnswering: Bool
    let onConnection: (BotConnectionOperation.Answer) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var values: [String: String] = [:]

    private var canAct: Bool { isEnabled && !isAnswering }

    private var env: [String: String] { target.env(from: values) }

    private var canConnect: Bool { canAct && target.accepts(env) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                stateLabel
            }
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            guidance
            if target.canConnect {
                ForEach(target.requiredEnv) { field in envField(field) }
            }
            if target.canSkip || target.canConnect || target.linkToOpen != nil {
                buttons
            }
        }
        .pendingRequestBlockSurface()
        .accessibilityElement(children: .contain)
    }

    /// Only MCP rows say what they are; a connector row's name is the whole story.
    private var subtitle: String? {
        guard target.kind == .mcp else { return nil }
        switch target.action {
        case .install: return String(localized: "MCP server · Install")
        case .enable: return String(localized: "MCP server · Enable")
        case .authorize: return String(localized: "MCP server · Sign in")
        default: return String(localized: "MCP server")
        }
    }

    /// The host's own words for the row, most specific first, each once.
    private var notes: [String] {
        var seen = Set<String>()
        return [target.discoveryError, target.detail, target.instructions].compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    private var stateLabel: some View {
        let (title, symbol, tint): (String, String?, Color) = switch target.state {
        case .pending, .initiated: (String(localized: "Waiting"), nil, .secondary)
        case .connected: (String(localized: "Connected"), "checkmark.circle.fill", .green)
        case .skipped: (String(localized: "Skipped"), nil, .secondary)
        case .failed: (String(localized: "Failed"), "exclamationmark.circle.fill", .red)
        case .expired: (String(localized: "Expired"), "clock.badge.exclamationmark", .red)
        case .notConnected: (String(localized: "Not connected"), nil, .secondary)
        case .unavailable: (String(localized: "Unavailable"), nil, .secondary)
        case nil: (String(localized: "Unknown"), nil, .secondary)
        }
        return HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .fixedSize()
    }

    /// Where this row finishes, when that is not the obvious button.
    @ViewBuilder private var guidance: some View {
        if target.finishesOnTheMac {
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish on the Mac.").font(.caption.weight(.semibold))
                Text("This sign-in returns to a browser on the Mac, so it can’t complete on iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if target.linkToOpen != nil {
            Text("Opens in your browser. Hermes notices when you finish.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if target.canSkip, !target.canConnect, target.state == .failed || target.state == .expired {
            // Trying again from here is deferred; asking the bot covers it.
            Text("Skip it and ask the bot to try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if let url = target.linkToOpen {
                // The browser, not an in-app sheet: the user's saved sign-ins are
                // there, and the host notices the new account without a callback.
                Button { openURL(url) } label: {
                    Label("Open link", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.primary))
                .disabled(!isEnabled)
                .accessibilityLabel(Text("Open link for \(target.name)"))
            } else if target.canConnect {
                Button(action: connect) {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.primary))
                .disabled(!canConnect)
                .accessibilityLabel(Text("Connect \(target.name)"))
            }
            if target.canSkip {
                Button { onConnection(.skip(target: target.name)) } label: {
                    Text("Skip").frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(!canAct)
                .accessibilityLabel(Text("Skip \(target.name)"))
            }
        }
    }

    private func envField(_ field: BotConnectionOperation.EnvField) -> some View {
        // At accessibility sizes the badge goes under the name, so a long
        // variable name keeps the line to itself instead of breaking mid-word.
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        return VStack(alignment: .leading, spacing: 6) {
            header {
                Text(verbatim: field.name)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if field.isSecret {
                    Text("secret").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                } else if !field.isRequired {
                    Text("optional").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let prompt = field.prompt {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if field.isSecret {
                    SecureField("Secret value", text: binding(for: field))
                        .textContentType(.password)
                } else {
                    TextField(String(localized: "Value"), text: binding(for: field))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(connect)
            .pendingRequestFieldSurface()
            .disabled(!canAct)
            .accessibilityLabel(Text(verbatim: field.name))
        }
    }

    private func binding(for field: BotConnectionOperation.EnvField) -> Binding<String> {
        Binding(get: { field.value(in: values) }, set: { values[field.name] = $0 })
    }

    private func connect() {
        guard canConnect else { return }
        let outgoing = env
        // Dropped from the view as it is handed over; the model never holds it.
        values = [:]
        onConnection(.connect(target: target.name, env: outgoing))
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
