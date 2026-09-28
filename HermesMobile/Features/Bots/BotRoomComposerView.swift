import SwiftUI

/// The Bot editor and mention panel, with only the controls rooms support.
struct BotRoomComposerView: View {
    @Bindable var reader: BotRoomReader
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @State private var selection = ComposerSelection()
    @State private var focused = false
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 16

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 8) {
                if focused, reader.mayEditDraft,
                   let trigger = BotMentionTrigger.detect(in: reader.draft, selection: selection.range) {
                    let completions = BotRoomMentions.completions(room: reader.room, query: trigger.query)
                    if !completions.isEmpty {
                        BotMentionAutocompleteView(completions: completions, avatars: avatars, room: reader.room, roster: roster) { item in
                            let result = trigger.applying(tag: item.tag, to: reader.draft)
                            reader.draft = result.draft
                            selection = selection.moved(to: result.selection)
                        }
                    }
                }
                HStack(spacing: 4) {
                    ComposerTextInputView(
                        text: $reader.draft, selection: $selection, isFocused: $focused,
                        inputHeight: $inputHeight, measuredHeight: $measuredHeight,
                        isDisabled: !reader.mayEditDraft, isCollapsed: !focused,
                        isKeyboardSendEnabled: reader.maySend, verticalPadding: 12,
                        chipSkills: [], chipFilePaths: [], quotes: [], onKeyboardSend: send,
                        onPasteFileProviders: { _ in }, onPasteFileURLs: { _ in },
                        onPasteImageProviders: { _ in }, onPasteImages: { _ in },
                        onTapChip: { _ in }, onTapQuote: { _ in }, onRemoveQuote: { _ in },
                        placeholder: String(localized: "Message \(reader.room.name)"), acceptsAttachments: false
                    )
                    actionButton
                }
                .padding(ChatComposerMetrics.pillInset)
                .modifier(ChatComposerSurfaceStyle(isExpanded: focused))
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var actionButton: some View {
        let stop = reader.showsStop
        let enabled = stop ? reader.mayStop : reader.maySend
        let appearance = ChatComposerActionAppearance(isStop: stop, isDisabled: !enabled,
            colorScheme: colorScheme, tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex)
        return Button {
            if stop { Task { await reader.stop() } } else { send() }
        } label: {
            Group {
                if reader.awaitingStop || reader.status.stopping > 0 {
                    Text("Stopping…").font(.caption).padding(.horizontal, 8)
                } else {
                    Image(systemName: stop ? "stop.fill" : "arrow.up")
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: ChatComposerMetrics.actionSize)
                }
            }
            .frame(minHeight: ChatComposerMetrics.actionSize)
            .background(appearance.background).foregroundStyle(appearance.foreground).clipShape(Capsule())
        }
        .buttonStyle(.chatTactile(.icon)).disabled(!enabled)
        .accessibilityLabel(stop ? Text("Stop every bot in this room") : Text("Send"))
    }

    private func send() { Task { await reader.send() } }
}

/// Room handles are server routing keys. Friendly names only help searching;
/// unlike Bot Chat, room sends must never append an identification annotation.
enum BotRoomMentions {
    static func completions(room: BotGroupRoom, query: String) -> [BotMentions.Completion] {
        let members = room.members.compactMap { member -> BotMentions.Completion? in
            guard let handle = member.handle, !handle.isEmpty,
                  let profile = BotProfile(.object(["name": .string(member.id), "display_name": .string(member.name)])) else { return nil }
            return BotMentions.Completion(profile: profile, tag: handle)
        }
        let everyone = ["all", "everyone"].compactMap { tag -> BotMentions.Completion? in
            guard let profile = BotProfile(.object(["name": .string("room-mention:" + tag),
                "display_name": .string(String(localized: "Everyone"))])) else { return nil }
            return BotMentions.Completion(profile: profile, tag: tag)
        }
        return Array((members + everyone).filter {
            query.isEmpty || $0.tag.localizedStandardContains(query) || $0.profile.name.localizedStandardContains(query)
        }.prefix(8))
    }
}

struct BotRoomActionCard: View {
    let reader: BotRoomReader
    let action: BotRoomAction
    var body: some View {
        if let approval = action.approval {
            BotPendingRequestCard(request: .approval(approval), identity: identity,
                isEnabled: reader.mayAct(action), canStop: reader.mayStop,
                isAnswering: reader.busy && reader.inactiveActions.contains(action.id), resolution: nil,
                onApprove: { choice in Task { await reader.act(action, choice: choice) } },
                onAnswer: { _ in }, onSkip: {}, onCredential: { _ in }, canDecline: false, onDecline: {},
                onStop: { Task { await reader.stop() } }, onConnection: { _ in })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(identity).font(.caption).foregroundStyle(.secondary)
                if action.isRetry {
                    Button("Retry") { Task { await reader.act(action) } }.disabled(!reader.mayAct(action))
                } else {
                    Label("Needs attention. Answer the request in Hermes Desktop on this same connection.", systemImage: "desktopcomputer")
                        .font(.callout)
                }
            }
            .padding(16).frame(maxWidth: 560, alignment: .leading)
            .pendingRequestCardSurface(cornerRadius: BotPendingRequestCard.cornerRadius)
        }
    }
    private var identity: String {
        let member = reader.room.members.first { $0.id == action.id.member }
        return [member?.name, reader.room.name, reader.connection.name].compactMap { $0 }.joined(separator: " · ")
    }
}
