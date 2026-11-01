import Foundation
import Observation
import SwiftUI

/// The request owner supplies a scoped identity and a guarded read on its existing connection.
@MainActor struct ApprovalSummaryPresentation {
    let key: ApprovalSummaries.Key
    var summaries: ApprovalSummaries = .shared
    let load: @MainActor () async throws -> String
}

/// Optional model text, with no relationship to the approval controls' enabled state.
/// Mount it only while the switch is on. The request outlives this view: a remount (a
/// question taking the card's place, a room card moving up, a layout change) keeps it,
/// and only an accepted answer, a withdrawal, leaving, or the switch turning off ends it.
struct ApprovalSummaryLine: View {
    let presentation: ApprovalSummaryPresentation
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault

    var body: some View {
        Group {
            switch presentation.summaries.states[presentation.key] ?? .loading {
            case .loading:
                VStack(alignment: .leading, spacing: 4) {
                    Text("In plain words (AI summary)").font(.caption.weight(.semibold))
                    Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
                }
            case .ready(let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text("In plain words (AI summary)").font(.caption.weight(.semibold))
                    Text(verbatim: text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            case .unavailable:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: presentation.key) {
            await presentation.summaries.show(presentation.key, load: presentation.load)
        }
        .onDisappear { if !explainsApprovals { presentation.summaries.cancel(presentation.key) } }
    }
}

/// A single iPhone-wide opt-in switch, used by every direct-Hermes approval surface.
struct ApprovalSummarySettingsSection: View {
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault

    var body: some View {
        Section {
            Toggle(isOn: $explainsApprovals) {
                SettingsLabel(title: String(localized: "Explain approvals in plain words"), systemImage: "text.bubble")
            }
        } footer: {
            Text("Asks the Hermes server’s model for a short summary of each approval. Chats on a webui server don’t show one.")
        }
    }
}

/// Memory-only state for one pending approval lifetime, not one presentation of its card.
@MainActor @Observable final class ApprovalSummaries {
    static let shared = ApprovalSummaries()
    static let enabledKey = "chat.explainApprovalsInPlainWords"
    /// Off until the user opts in: each summary is a model call on their server.
    static let enabledByDefault = false

    /// The app's display language named in English, so the summary reads in the user's language.
    nonisolated static func language(_ identifier: String = Bundle.main.preferredLocalizations.first ?? "en") -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? "English"
    }

    static func input(description: String?, command: String?, cwd: String?) -> String? {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var lines: [String] = []
        if let description, !description.isEmpty { lines.append("Why it was flagged: \(description)") }
        lines.append("Command: \(command)")
        if let cwd, !cwd.isEmpty { lines.append("Working directory: \(cwd)") }
        return lines.joined(separator: "\n")
    }

    struct Scope: Hashable {
        enum Conversation: Hashable {
            case session(profile: String, key: String)
            case room(id: String, epoch: Int?)
        }
        let server: URL
        let connectionID: UUID
        let conversation: Conversation
    }

    struct Key: Hashable {
        enum Request: Hashable {
            case approval(String)
            case room(BotRoomAction.Identity)
        }
        let scope: Scope
        let request: Request
    }

    enum State: Equatable {
        case loading
        case ready(String)
        case unavailable
    }

    private(set) var states: [Key: State] = [:]

    private struct Request {
        let token = UUID()
        let task: Task<String, Error>
    }
    @ObservationIgnored private var requests: [Key: Request] = [:]

    /// Leaving or turning the switch off ends unfinished work, but never
    /// makes a still-pending approval eligible for a second model request.
    func cancel(_ key: Key) {
        guard let request = requests.removeValue(forKey: key) else { return }
        request.task.cancel()
        states[key] = .unavailable
    }

    /// A single request the host explicitly settled or withdrew.
    func remove(_ key: Key) {
        cancel(key)
        states[key] = nil
    }

    func leave(_ scope: Scope) {
        for key in Array(requests.keys) where key.scope == scope { cancel(key) }
    }

    /// Call only with a host-confirmed pending set, never a navigation/reset's empty UI.
    func retain(_ keys: Set<Key>, in scope: Scope) {
        for key in Array(states.keys) where key.scope == scope && !keys.contains(key) {
            remove(key)
        }
    }

    func show(_ key: Key, load: @escaping @MainActor () async throws -> String) async {
        guard states[key] == nil, !Task.isCancelled else { return }
        states[key] = .loading
        // Unstructured, so the presenting view's task ending doesn't cancel it.
        let request = Request(task: Task { try await load() })
        requests[key] = request
        let result = await request.task.result
        // Cancellation/pruning owns the state once it removes the request. A late reply
        // must not repopulate a finished approval, even if its loader ignores cancellation.
        guard requests[key]?.token == request.token else { return }
        requests[key] = nil
        if !request.task.isCancelled, case .success(let value) = result {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            states[key] = text.isEmpty ? .unavailable : .ready(text)
        } else {
            states[key] = .unavailable
        }
    }
}
