import SwiftUI
import UIKit

/// Who a request card says is waiting: Bot Chat names the bot, a regular Hermes chat names
/// Hermes (#1141). Each sentence is translated whole, per subject.
enum HermesRequestSubject {
    case bot, hermes
}

/// A request only Hermes Desktop answers: work its renderer does by itself, with no answer a
/// person gives. The host releases the agent on its own deadline, so the card reports the
/// wait and keeps Stop for the user who does not want to wait it out. Bot Chat's request card
/// and a Hermes chat's request slot both show it.
struct HermesDesktopTaskRequestBody: View {
    let task: BotDesktopTaskRequest
    let identity: String
    let subject: HermesRequestSubject
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        HermesRequestHeader(
            systemImage: "desktopcomputer", tint: .secondary,
            title: String(localized: "Hermes Desktop is handling this"), identity: identity
        )
        Text(task.kind.title(subject))
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        Text(task.kind.detail(subject))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button(role: .destructive, action: onStop) {
            Label("Stop current work", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.destructive))
        .disabled(!canStop)
    }
}

/// A `manage_connections` operation: one row per app, in the host's order, each with only the
/// moves the host allows for its kind and state. Continue without is the one control that
/// releases the agent whatever the rows say, so it stays until the settled frame removes the
/// card. The deadline is the host's, shown in whole minutes and redrawn once a minute, never
/// animated.
struct HermesConnectionRequestBody: View {
    let operation: BotConnectionOperation
    let identity: String
    let subject: HermesRequestSubject
    let isEnabled: Bool
    let isAnswering: Bool
    let onConnection: (BotConnectionOperation.Answer) -> Void

    var body: some View {
        HermesRequestHeader(systemImage: "link", tint: .secondary, title: String(localized: "Connect apps"), identity: identity)
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.everyMinute) { context in
                let minutes = BotConnectionOperation.minutesLeft(until: operation.deadline, now: context.date)
                // The system's own unit wording, so every language gets its plural right.
                let left = Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
                Text("Waiting · \(left) left")
                    .font(.subheadline.weight(.semibold))
            }
            Text(pausedLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(operation.targets) { target in
            HermesConnectionTargetRow(target: target, subject: subject, isEnabled: isEnabled, isAnswering: isAnswering,
                                      onConnection: onConnection)
        }
        Button { onConnection(.continueWithout) } label: {
            Text("Continue without").frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(.secondary))
        .disabled(!isEnabled || isAnswering)
        Text(releaseLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pausedLine: String {
        switch subject {
        case .bot: return String(localized: "The bot is paused until each app is connected or skipped.")
        case .hermes: return String(localized: "Hermes is paused until each app is connected or skipped.")
        }
    }

    private var releaseLine: String {
        switch subject {
        case .bot: return String(localized: "Releases the bot now. Apps not connected stay off for this reply.")
        case .hermes: return String(localized: "Releases Hermes now. Apps not connected stay off for this reply.")
        }
    }
}

/// One app in a connection operation. A managed connector opens its sign-in in the browser;
/// an MCP enable or install connects here with a field per value it still needs; an MCP
/// sign-in only finishes at the Mac. Setup values live in this row's state alone, are masked
/// when secret, and are dropped the moment they are handed over.
private struct HermesConnectionTargetRow: View {
    let target: BotConnectionOperation.Target
    let subject: HermesRequestSubject
    let isEnabled: Bool
    let isAnswering: Bool
    let onConnection: (BotConnectionOperation.Answer) -> Void

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
            // Trying again from here is deferred; asking the agent covers it.
            Text(retryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retryLine: String {
        switch subject {
        case .bot: return String(localized: "Skip it and ask the bot to try again.")
        case .hermes: return String(localized: "Skip it and ask Hermes to try again.")
        }
    }

    private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if let url = target.linkToOpen {
                // The browser, not an in-app sheet: the user's saved sign-ins are
                // there, and the host notices the new account without a callback.
                // Opened directly, so the transcript's link router never takes it.
                Button { UIApplication.shared.open(url) } label: {
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

/// A request card's header: its symbol, what is asked, and who asks.
struct HermesRequestHeader: View {
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
