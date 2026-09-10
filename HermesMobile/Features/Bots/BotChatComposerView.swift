import SwiftUI

/// Sessions presentation with Bot-owned draft and action rules. The same editor
/// stays mounted through focus changes; no webui runtime controls are involved.
struct BotChatComposerView: View {
    let model: BotConversation
    let onStop: () -> Void
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 16
    @State private var isFocused = false
    @State private var selection = ComposerSelection()
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    @State private var keyboardIsVisible = false

    private var showsStop: Bool { model.mayStop || model.turn == .stopping }
    private var canSend: Bool {
        model.maySend && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var actionDisabled: Bool { showsStop ? !model.mayStop : !canSend }
    private var appearance: ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: showsStop, isDisabled: actionDisabled, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
    }

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                BotChatStatusView(model: model, onReconnect: onReconnect, onResolveHeldMessage: onResolveHeldMessage)

                HStack(alignment: .center, spacing: 4) {
                    ComposerTextInputView(
                        text: Binding(get: { model.draft }, set: { model.editDraft($0) }),
                        selection: $selection, isFocused: $isFocused,
                        inputHeight: $inputHeight, measuredHeight: $measuredHeight,
                        isDisabled: !model.mayEditDraft, isCollapsed: !isFocused,
                        isKeyboardSendEnabled: canSend, verticalPadding: 12,
                        chipSkills: [], chipFilePaths: [], quotes: [],
                        onKeyboardSend: send,
                        onPasteFileProviders: { _ in }, onPasteFileURLs: { _ in },
                        onPasteImageProviders: { _ in }, onPasteImages: { _ in },
                        onTapChip: { _ in }, onTapQuote: { _ in }, onRemoveQuote: { _ in },
                        placeholder: String(localized: "Message bot"), acceptsAttachments: false
                    )
                    if !isFocused { actionButton }
                }
                .padding(.trailing, isFocused ? 0 : ChatComposerMetrics.pillInset)
                .padding(.vertical, isFocused ? 0 : ChatComposerMetrics.pillInset)
                .padding(.top, isFocused ? 2 : 0)
                .padding(.bottom, isFocused ? 4 : 0)
                .modifier(ChatComposerSurfaceStyle(isExpanded: isFocused))
                .padding(.horizontal, 16)

                if isFocused {
                    HStack {
                        Spacer(minLength: 0)
                        actionButton
                    }
                    .padding(.horizontal, 16)
                    // Sessions adds a 6 pt stack gap before its 8 pt toolbar inset.
                    .padding(.top, 14)
                    .background(
                        Color(.systemBackground)
                            .padding(.top, -10).padding(.bottom, -12)
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            // Focus flips arrive from UIKit outside any withAnimation, so the
            // pill-to-card morph and the row's insertion animate from here,
            // exactly as the Sessions composer does.
            .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: isFocused)
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
    }

    private var actionButton: some View {
        Button {
            if showsStop { onStop() } else { send() }
        } label: {
            Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                .font(.system(size: actionIconSize, weight: .semibold))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .background(appearance.background)
                .foregroundStyle(appearance.foreground)
                .clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(actionDisabled)
        .accessibilityLabel(showsStop ? Text("Stop current work") : Text("Send"))
        .keyboardShortcut(showsStop ? nil : KeyboardShortcut(.return, modifiers: .command))
    }

    private func send() {
        guard canSend else { return }
        Task { await model.send() }
    }
}

/// Ready and connected has no status chrome. Recovery, work and failures appear
/// immediately above the composer, including the existing Desktop-only actions.
private struct BotChatStatusView: View {
    let model: BotConversation
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void

    var body: some View {
        if model.connectionState != .connected || model.turn != .idle || model.errorMessage != nil || model.uncertainSend {
            VStack(alignment: .leading, spacing: 6) {
                if let connectionText { Text(connectionText) }
                if let error = model.errorMessage { Text(error) }
                if model.uncertainSend {
                    Text("Send outcome unknown. Check the conversation in Desktop before sending again.")
                    if model.connectionState == .connected {
                        Button("Resolve held message…", action: onResolveHeldMessage)
                    }
                } else if model.turn == .needsAttention {
                    // The model ranks a pending request above an unresolved Stop;
                    // the Desktop instruction is the actionable line, so it wins here too.
                    Text("Needs attention. Answer the request in Hermes Desktop on this same connection.")
                } else if model.uncertainStop && model.turn != .stopping {
                    Text("Outcome unknown")
                } else if model.connectionState == .connected, let turnText {
                    Text(turnText)
                }
                if model.connectionState == .disconnected {
                    Button("Reconnect", action: onReconnect)
                }
            }
            .font(AppFont.footnote())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bot-chat-status")
        }
    }

    private var connectionText: String? {
        switch model.connectionState {
        case .connected: return nil
        case .recovering: return String(localized: "Loading current conversation…")
        case .disconnected: return String(localized: "Disconnected · Last loaded conversation")
        }
    }

    private var turnText: String? {
        switch model.turn {
        case .idle, .needsAttention: return nil
        case .running: return String(localized: "Working")
        case .submitting: return String(localized: "Sending…")
        case .stopping: return String(localized: "Stopping…")
        case .uncertain: return String(localized: "Outcome unknown")
        case .interrupted: return String(localized: "Work was interrupted. The saved conversation is loaded.")
        case .unknown: return String(localized: "Checking current work…")
        }
    }
}
