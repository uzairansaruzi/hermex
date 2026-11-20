import SwiftUI

struct ProfileServingSection: View {
    let serving: HermesProfileServing?
    let connection: BotConnection
    let server: URL
    let onServed: () -> Void

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
