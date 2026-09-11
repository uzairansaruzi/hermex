import SwiftUI
import UIKit

/// Sessions presentation with Bot-owned draft and action rules. The same editor
/// stays mounted through focus changes; no webui runtime controls are involved.
struct BotChatComposerView: View {
    let model: BotConversation
    let onStop: () -> Void
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void
    /// Scrolls the transcript back to the pending request card.
    let onShowRequest: () -> Void

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

    @State private var mode = BotPromptMode.send
    @State private var redirectAction: BotConversation.PromptAction?

    private var showsToolbar: Bool { isFocused || !model.draft.isEmpty || mode != .send }
    private var showsStop: Bool { model.mayStop || model.turn == .stopping }
    private var canSend: Bool {
        model.maySubmit(mode) && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var appearance: ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: false, isDisabled: !canSend, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
    }

    var body: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                BotChatStatusView(
                    model: model, onReconnect: onReconnect,
                    onResolveHeldMessage: onResolveHeldMessage, onShowRequest: onShowRequest
                )

                if mode != .send && model.maySend {
                    Text("Work finished. Choose Send to start a new turn.")
                        .font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

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
                    if !showsToolbar {
                        if showsStop { stopButton } else { actionButton }
                    }
                }
                .padding(.trailing, isFocused ? 0 : ChatComposerMetrics.pillInset)
                .padding(.vertical, isFocused ? 0 : ChatComposerMetrics.pillInset)
                .padding(.top, isFocused ? 2 : 0)
                .padding(.bottom, isFocused ? 4 : 0)
                .modifier(ChatComposerSurfaceStyle(isExpanded: isFocused))
                .padding(.horizontal, 16)

                if showsToolbar {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            modeMenu
                            Spacer(minLength: 8)
                            promptButtons
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            modeMenu
                            HStack { Spacer(minLength: 0); promptButtons }
                        }
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
        .onChange(of: model.mayGuide) { _, busy in
            if busy && mode == .send { mode = .steer }
        }
        .onAppear { if model.mayGuide && mode == .send { mode = .steer } }
        .confirmationDialog("Redirect this bot's current work?", isPresented: Binding(
            get: { redirectAction != nil }, set: { if !$0 { redirectAction = nil } }
        ), titleVisibility: .visible) {
            if let action = redirectAction {
                Button("Redirect", role: .destructive) {
                    redirectAction = nil
                    Task { await model.submit(action) }
                }
            }
            Button("Cancel", role: .cancel) { redirectAction = nil }
        } message: {
            Text("Interrupt current work and send this direction? During startup, the server may queue it for the next turn.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
    }

    private var modeMenu: some View {
        ChatUIKitMenuButton {
            ComposerInlineControlLabel(
                title: mode.title, systemImage: "arrow.turn.up.right",
                color: .secondary, controlFont: AppFont.subheadline(), chevronFont: AppFont.caption2()
            )
        } menu: {
            UIMenu(children: BotPromptMode.allCases.map { option in
                UIAction(title: option.title, subtitle: option.explanation,
                         attributes: model.maySubmit(option) ? [] : [.disabled],
                         state: mode == option ? .on : .off) { _ in
                    mode = option
                }
            })
        }
        .accessibilityLabel(Text("Message action: \(mode.title)"))
        .accessibilityHint(Text(mode.explanation))
    }

    private var promptButtons: some View {
        HStack(spacing: 8) {
            if showsStop { stopButton }
            actionButton
        }
    }

    private var stopButton: some View {
        let colors = ChatComposerActionAppearance(
            isStop: true, isDisabled: !model.mayStop, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
        return Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: actionIconSize, weight: .semibold))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .background(colors.background).foregroundStyle(colors.foreground).clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(!model.mayStop)
        .accessibilityLabel("Stop current work")
    }

    private var actionButton: some View {
        Button(action: send) {
            HStack(spacing: 6) {
                if showsToolbar { Text(mode.title).font(AppFont.subheadline()) }
                Image(systemName: "arrow.up")
                    .font(.system(size: actionIconSize, weight: .semibold))
            }
            .padding(.horizontal, showsToolbar ? 14 : 0)
            .frame(minWidth: ChatComposerMetrics.actionSize, minHeight: ChatComposerMetrics.actionSize)
            .background(appearance.background)
            .foregroundStyle(appearance.foreground)
            .clipShape(Capsule())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(!canSend)
        .accessibilityLabel(Text(mode.title))
        .accessibilityHint(Text(mode.explanation))
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func send() {
        guard let action = model.preparePrompt(mode) else { return }
        if mode == .redirect { redirectAction = action }
        else { Task { await model.submit(action) } }
    }
}

/// Ready and connected has no status chrome. Recovery, work and failures appear
/// immediately above the composer, including the existing Desktop-only actions.
private struct BotChatStatusView: View {
    let model: BotConversation
    let onReconnect: () -> Void
    let onResolveHeldMessage: () -> Void
    let onShowRequest: () -> Void

    var body: some View {
        if model.connectionState != .connected || model.turn != .idle || model.errorMessage != nil || model.uncertainSend
            || model.promptReceipt != nil || !model.liveActivity.notices.isEmpty || !model.liveActivity.memoryNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let connectionText { Text(connectionText) }
                ForEach(model.liveActivity.notices) { notice in
                    Label(notice.text, systemImage: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
                }
                ForEach(model.liveActivity.memoryNotes, id: \.self) { note in
                    Label(note, systemImage: "brain")
                }
                if let error = model.errorMessage { Text(error) }
                if let receipt = model.promptReceipt { Text(receipt) }
                if model.submittingPrompt != nil {
                    Text("Sending…")
                } else if model.uncertainSend {
                    Text("Message outcome unknown. Check the conversation in Desktop before sending again.")
                    if model.connectionState == .connected {
                        Button("Resolve held message…", action: onResolveHeldMessage)
                    }
                } else if model.turn == .needsAttention {
                    // The model ranks a pending request above an unresolved Stop, so
                    // the actionable line wins here too. The card is in the transcript
                    // and may be scrolled away, so this doubles as the way back to it.
                    if model.pendingRequest != nil {
                        Button(action: onShowRequest) {
                            Label(requestText, systemImage: "arrow.down.circle")
                        }
                    } else {
                        // A pending key the phone could not read has no card to show.
                        Text("Needs attention. Answer the request in Hermes Desktop on this same connection.")
                    }
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

    /// What the blocked bot is waiting on. "Handling this" is only true where
    /// there is nothing to do: a request the phone can answer or decline has an
    /// action on its card, and saying it is handled would hide that.
    private var requestText: String {
        if model.pendingRequest?.isAnswerable == true { return String(localized: "Waiting for your answer") }
        if model.mayDecline { return String(localized: "Waiting on Hermes Desktop") }
        return String(localized: "Hermes Desktop is handling this")
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
        case .running: return model.workStatus ?? String(localized: "Working")
        case .submitting: return String(localized: "Sending…")
        case .stopping: return String(localized: "Stopping…")
        case .uncertain: return String(localized: "Outcome unknown")
        case .interrupted: return String(localized: "Work was interrupted. The saved conversation is loaded.")
        case .unknown: return String(localized: "Checking current work…")
        }
    }
}
