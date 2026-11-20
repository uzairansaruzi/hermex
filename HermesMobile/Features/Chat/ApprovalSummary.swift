import Foundation
import Observation
import SwiftUI

@MainActor struct ApprovalSummaryPresentation {
    let key: ApprovalSummaries.Key
    var summaries: ApprovalSummaries = .shared
    let load: @MainActor () async throws -> String
}

struct ApprovalSummaryLine: View {
    let presentation: ApprovalSummaryPresentation
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault

    var body: some View {
        Group {
            switch presentation.summaries.states[presentation.key] ?? .loading {
            case .loading:
                VStack(alignment: .leading, spacing: 4) {
                    Text("In plain words (AI summary)").font(AppFont.caption(weight: .semibold))
                    Text("Summarizing…").font(AppFont.caption()).foregroundStyle(.appSecondary)
                }
            case .ready(let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text("In plain words (AI summary)").font(AppFont.caption(weight: .semibold))
                    Text(verbatim: text).font(AppFont.subheadline()).fixedSize(horizontal: false, vertical: true)
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

struct ApprovalSummarySettingsSection: View {
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault

    var body: some View {
        Section {
            Toggle(isOn: $explainsApprovals) {
                SettingsLabel(title: String(localized: "Explain approvals in plain words"), systemImage: "text.bubble")
            }
        } appFooter: {
            Text("Asks the Hermes server’s model for a short summary of each approval. Chats on a webui server don’t show one.")
        }
    }
}

@MainActor @Observable final class ApprovalSummaries {
    static let shared = ApprovalSummaries()
    static let enabledKey = "chat.explainApprovalsInPlainWords"
    static let enabledByDefault = false

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

    func cancel(_ key: Key) {
        guard let request = requests.removeValue(forKey: key) else { return }
        request.task.cancel()
        states[key] = .unavailable
    }

    func remove(_ key: Key) {
        cancel(key)
        states[key] = nil
    }

    func leave(_ scope: Scope) {
        for key in Array(requests.keys) where key.scope == scope { cancel(key) }
    }

    func retain(_ keys: Set<Key>, in scope: Scope) {
        for key in Array(states.keys) where key.scope == scope && !keys.contains(key) {
            remove(key)
        }
    }

    func show(_ key: Key, load: @escaping @MainActor () async throws -> String) async {
        guard states[key] == nil, !Task.isCancelled else { return }
        states[key] = .loading
        let request = Request(task: Task { try await load() })
        requests[key] = request
        let result = await request.task.result
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
