#if DEBUG
import SwiftUI

/// Debug-only fixture for reviewing compatibility copy and retry states. It
/// deliberately has no client or server URL, so exercising it cannot read or
/// mutate an authenticated Kanban server.
struct KanbanLabView: View {
    @State private var scenario: KanbanLabScenario = .compatible
    @State private var retryCount = 0

    var body: some View {
        Form {
            Section {
                Picker("State", selection: $scenario) {
                    ForEach(KanbanLabScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
            } header: {
                Text("Fixture")
            } footer: {
                Text("This lab uses local fixtures only. It never contacts or changes a Kanban server.")
            }

            Section("Compatibility") {
                stateContent
            }
        }
        .navigationTitle("Kanban Lab")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch scenario {
        case .compatible:
            Label("This server is compatible with Kanban.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .partial:
            VStack(alignment: .leading, spacing: 8) {
                Label("Kanban is available with limited capabilities.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Some server values are unsupported. Editing remains unavailable.")
            }
        case .authentication:
            VStack(alignment: .leading, spacing: 8) {
                Label("Sign in is required for Kanban.", systemImage: "lock")
                Text("Return to the server login screen, then try again.")
            }
        case .network:
            retryContent(
                title: "Kanban could not reach the server.",
                detail: "Known Kanban data remains unavailable until a connection succeeds."
            )
        case .serverUnavailable:
            retryContent(
                title: "The Kanban server is unavailable.",
                detail: "Check that the Hermes server is awake, then try again."
            )
        case .incompatible:
            retryContent(
                title: "This server's Kanban response is incompatible with Hermex.",
                detail: "No Kanban changes were made."
            )
        }
    }

    private func retryContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(detail)
            Button("Try Again") {
                retryCount += 1
            }
            .accessibilityHint("Simulates a retry without contacting a server.")
            if retryCount > 0 {
                Text("Retry simulated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum KanbanLabScenario: String, CaseIterable, Identifiable {
    case compatible
    case partial
    case authentication
    case network
    case serverUnavailable
    case incompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatible: "Compatible"
        case .partial: "Partial"
        case .authentication: "Authentication"
        case .network: "Network"
        case .serverUnavailable: "Server unavailable"
        case .incompatible: "Incompatible"
        }
    }
}
#endif
