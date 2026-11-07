import SwiftUI

/// The active Hermes server's Profiles section while its gateway's Webapp serves only one
/// Profile (#1611): how many it serves, why in plain words, and the host's own words. Shows
/// nothing on a dashboard, which serves every Profile, or once the Webapp serves them all.
struct ProfileServingSection: View {
    let connection: BotConnection
    let server: URL

    @State private var serving: HermesProfileServing?

    var body: some View {
        Group {
            if let serving, let reason = serving.reason {
                Section {
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
                    HostReasonDisclosure(text: reason.hostText)
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("This Webapp opens chats only on the Profile it serves.")
                }
            }
        }
        .task(id: server) {
            let http = HermesConnections.shared.connection(for: connection, server: server)
            // The read signs in first when needed, which is what tells a Webapp from a dashboard.
            guard let read = try? await HermesProfileServing.read(on: http), http.servesWebapp else { return }
            serving = read
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
