import SwiftUI

/// The active Hermes server's Profiles section while its gateway's Webapp serves only one
/// Profile (#1611): how many it serves, why in plain words, the host's own words, and the way to
/// serve every Profile (`ServeEveryProfileView`). Shows nothing until `serving` reports a reason,
/// so the page reads it (`read(connection:server:)`): an empty section's own task never runs.
struct ProfileServingSection: View {
    let serving: HermesProfileServing?
    let connection: BotConnection
    let server: URL
    /// Called once the Webapp serves every Profile.
    let onServed: () -> Void

    /// What the Webapp at `server` says about the Profiles it serves; nil on a dashboard, which
    /// serves every Profile itself, or when the read fails. The read signs in first when needed,
    /// which is what tells a Webapp from a dashboard.
    static func read(connection: BotConnection, server: URL) async -> HermesProfileServing? {
        let http = HermesConnections.shared.connection(for: connection, server: server)
        guard let read = try? await HermesProfileServing.read(on: http), http.servesWebapp else { return nil }
        return read
    }

    var body: some View {
        if let serving, let reason = serving.reason {
            Section {
                NavigationLink {
                    ServeEveryProfileView(connection: connection, server: server, profile: nil, onServed: onServed)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Profiles served: 1 of \(serving.profileCount)")
                            Text(reason.summary ?? String(localized: "The host serves only one Profile right now."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                HostReasonDisclosure(text: reason.hostText)
            } header: {
                Text("Profiles")
            } footer: {
                Text("This Webapp opens chats only on the Profile it serves. Tap to serve every Profile.")
            }
        }
    }
}

/// The host's own words for why something failed, collapsed under Hermex's plain summary.
struct HostReasonDisclosure: View {
    let text: String

    var body: some View {
        DisclosureGroup("What the host says") {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
