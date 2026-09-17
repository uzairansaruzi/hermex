import SwiftUI

/// A frozen local snapshot, with no transport or conversation owner. Its row IDs
/// address this saved projection only and are never sent to the host.
struct BotCachedHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let hit: BotHistoryCache.Hit
    let profile: BotProfile
    @State private var scrollID: String?
    @State private var positioned = false

    init(hit: BotHistoryCache.Hit, profile: BotProfile) {
        self.hit = hit; self.profile = profile
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Messages saved on this iPhone")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(hit.snapshot.savedAt, format: .dateTime.month().day().hour().minute())
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(hit.snapshot.messages) { message in
                        let chatMessage = ChatMessage(
                            role: message.role,
                            content: message.text,
                            timestamp: nil,
                            messageId: message.id,
                            displayKind: message.displayKind
                        )
                        if chatMessage.isSteerMessage {
                            // The same steer bubble as live Bot history.
                            MessageBubbleView(message: chatMessage, textOnly: true)
                                .id(message.id)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? String(localized: "You") : profile.name)
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(message.id == hit.message.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(16)
            }
            .scrollPosition(id: $scrollID, anchor: .center)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.containerSize.height > 0 && geometry.contentSize.height > 0
            } action: { _, ready in
                guard ready, !positioned else { return }
                positioned = true
                scrollID = hit.message.id
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
