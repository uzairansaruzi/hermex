import SwiftUI
import UIKit

/// Sessions presentation with Bot-owned draft and action rules. The same editor
/// stays mounted through focus changes; no webui runtime controls are involved.
struct BotChatComposerView: View {
    let model: BotConversation
    var mentionAvatars: [String: UIImage] = [:]
    let onStop: () -> Void
    let onReconnect: () -> Void
    /// Scrolls the transcript back to the pending request card.
    let onShowRequest: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var plusIconSize: CGFloat = 20
    @State private var shouldRestoreFocusAfterPicker = false
    @State private var picker: BotAttachmentPicker?
    @State private var preview: PendingAttachment?
    @State private var isFocused = false
    @State private var selection = ComposerSelection()
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    @State private var keyboardIsVisible = false
    @State private var voiceInput = ComposerVoiceInputController()

    @State private var settingsPresented = false
    @State private var mode = BotPromptMode.send
    @State private var redirectAction: BotConversation.PromptAction?

    private var isExpanded: Bool { isFocused || settingsPresented || picker != nil || shouldRestoreFocusAfterPicker || preview != nil || model.submittingPrompt != nil }
    private var showsToolbar: Bool { isExpanded || mode != .send }
    private var showsStop: Bool { model.mayStop || model.turn == .stopping }
    private var canSend: Bool {
        model.maySubmit(mode) && model.hasSendableInput
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
                    onShowRequest: onShowRequest
                )

                if mode != .send && model.maySend {
                    Text("Work finished. Choose Send to start a new turn.")
                        .font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

                if let error = model.chatControls.errorMessage {
                    Text(error).font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                if let pending = model.chatControls.pendingModel {
                    Text("Next turn: \(pending.displayName)").font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                if let error = model.attachments.errorMessage {
                    Text(error).font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                if model.attachments.isImporting {
                    Text("Adding attachment…").font(AppFont.footnote()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }
                if let voiceStatus {
                    ComposerVoiceStatusView(status: voiceStatus)
                }

                if isFocused, model.mayEditDraft { autocomplete }

                composerSurface.padding(.horizontal, 16)

                if showsToolbar {
                    HStack(alignment: .center, spacing: 8) {
                        ComposerToolbarScroller {
                            plusMenu
                            if model.mayGuide || mode != .send { modeMenu }
                            BotComposerSettings(settings: model.chatControls, preparePresentation: {
                                settingsPresented = true; isFocused = false
                            }, dismissPresentation: { settingsPresented = false })
                            voiceControlButton
                        }
                        promptButtons
                    }
                    .padding(.horizontal, 16)
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
            .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: isExpanded)
        }
        .modifier(BotAttachmentPickerPresentation(model: model, picker: $picker))
        .confirmationDialog("Change chat model?", isPresented: Binding(
            get: { model.chatControls.confirmation != nil },
            set: { if !$0 { model.chatControls.cancelConfirmation() } }
        ), titleVisibility: .visible) {
            if let confirmation = model.chatControls.confirmation {
                Button("Change model") {
                    model.chatControls.cancelConfirmation()
                    Task { await model.chatControls.apply(confirmation.action, confirmed: true) }
                }
                .disabled(!model.chatControls.mayChangeModel)
            }
            Button("Cancel", role: .cancel) { model.chatControls.cancelConfirmation() }
        } message: {
            if let confirmation = model.chatControls.confirmation { Text(confirmation.message) }
        }
        .sheet(item: $preview) { item in
            BotArtifactPreview(reference: TranscriptMediaReference(rawReference: item.name)) {
                try await model.attachments.data(for: item)
            }
        }
        .task(id: model.connectionState) { await model.loadSlashCatalog() }
        .onChange(of: model.chatControls.workspace) { _, _ in model.resetFileReferences() }
        .task(id: picker) {
            guard picker == nil, shouldRestoreFocusAfterPicker else { return }
            // Match Sessions' short delay while the native picker dismisses.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard picker == nil, shouldRestoreFocusAfterPicker else { return }
            shouldRestoreFocusAfterPicker = false
            if model.mayEditDraft { isFocused = true }
        }
        .onDisappear {
            shouldRestoreFocusAfterPicker = false
            voiceInput.stopBeforeSubmittingDraft()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { voiceInput.stopBeforeSubmittingDraft() }
        }
        // Ask Hermex lands the passage here, so the keyboard should already be
        // up for whatever the user wants to ask about it.
        .onChange(of: model.quotes.count) { previous, current in
            guard current > previous, model.mayEditDraft else { return }
            isFocused = true
        }
        .onChange(of: model.attachments.items.isEmpty) { _, empty in
            if !empty, mode == .steer || mode == .redirect { mode = model.mayGuide ? .queue : .send }
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
        .onChange(of: model.mayGuide) { _, busy in
            if busy && mode == .send { mode = model.attachments.items.isEmpty ? .steer : .queue }
        }
        .onAppear { if model.mayGuide && mode == .send { mode = model.attachments.items.isEmpty ? .steer : .queue } }
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

    /// The one panel the caret can open: bots and workspace files for an `@`,
    /// this connection's skills for a `/` that opens the draft. The `@` panel
    /// wins, so the two can never stack. The skill panel stays closed for Steer
    /// and Redirect, where the host will not expand an invocation.
    ///
    /// The `@` container stands whenever the caret sits in a reference, even
    /// while the panel itself is still empty: its task is what asks the host
    /// for rows, and the first answer is what makes the panel appear.
    @ViewBuilder private var autocomplete: some View {
        if let trigger = ComposerFileTrigger.detect(in: model.draft, selection: selection.range) {
            let botCompletions = model.mentions.completions(query: trigger.query)
            Group {
                if !botCompletions.isEmpty || !model.filePathSearch.matches.isEmpty || model.filePathSearch.isLoading {
                    BotAtAutocompleteView(
                        botCompletions: botCompletions,
                        avatars: mentionAvatars,
                        fileMatches: model.filePathSearch.matches,
                        isLoadingFiles: model.filePathSearch.isLoading,
                        onSelectBot: { item in
                            let result = trigger.applying("@" + item.tag + " ", to: model.draft)
                            model.editDraft(result.draft)
                            selection = selection.moved(to: result.selection)
                        },
                        onSelectFile: { match in
                            let result = trigger.applying(
                                match.isDirectory ? "@\(match.path)/" : "@\(match.path) ", to: model.draft
                            )
                            model.editDraft(result.draft)
                            selection = selection.moved(to: result.selection)
                            if !match.isDirectory { model.recordFileChipReference(match.path) }
                        }
                    )
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .task(id: trigger.query) { await model.searchFilePaths(trigger.query) }
        } else if mode.startsTurn,
                  let trigger = BotSlashTrigger.detect(in: model.draft, selection: selection.range) {
            let matches = SlashSkillFormatter.matching(trigger.query, in: model.slashSkills)
            if !matches.isEmpty {
                BotSlashAutocompleteView(suggestions: matches) { skill in
                    // The slug, exactly as Sessions completes a skill: it is what
                    // `ComposerChipCatalog` is keyed by, so the chip draws. The send
                    // path resolves it back to the host's own key before dispatch.
                    let result = trigger.applying("/" + skill.slashName + " ", to: model.draft)
                    model.editDraft(result.draft)
                    selection = selection.moved(to: result.selection)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    /// Same pill/card structure as the Sessions composer. The editor keeps its
    /// identity as the attachment strip and controls move around it.
    private var composerSurface: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ComposerAttachmentStripView(attachments: model.attachments.items, onRemove: { id in
                    Task { await model.attachments.remove(id) }
                }, onPreview: { preview = $0 })
                .disabled(!model.mayEditDraft || model.attachments.isImporting)
            }
            HStack(alignment: .center, spacing: 4) {
                ComposerTextInputView(
                    text: Binding(get: { model.draft }, set: { model.editDraft($0) }),
                    selection: $selection, isFocused: $isFocused,
                    inputHeight: $inputHeight, measuredHeight: $measuredHeight,
                    isDisabled: !model.mayEditDraft, isCollapsed: !isExpanded,
                    isKeyboardSendEnabled: canSend, verticalPadding: 12,
                    chipSkills: model.slashSkills, chipFilePaths: model.fileChipPaths,
                    chipBots: model.mentions.chipReferences(avatars: mentionAvatars), quotes: model.quotes,
                    onKeyboardSend: send,
                    onPasteFileProviders: { BotAttachmentPaste.providers($0, model: model) },
                    onPasteFileURLs: { BotAttachmentPaste.files($0, model: model) },
                    onPasteImageProviders: { BotAttachmentPaste.providers($0, model: model) },
                    onPasteImages: { BotAttachmentPaste.images($0, model: model) },
                    // Tapping a chip opens its full passage in issue #564; here it
                    // is inert, and the swipe-to-remove is the way back out.
                    onTapChip: { _ in }, onTapQuote: { _ in }, onRemoveQuote: { model.removeQuote($0) },
                    placeholder: String(localized: "Ask anything..."), acceptsAttachments: model.mayEditDraft
                )
                if !isExpanded {
                    ComposerAttachmentPillPreview(attachments: model.attachments.items, onPreview: { preview = $0 })
                    if !showsToolbar {
                        voiceControlButton
                        if showsStop { stopButton } else { actionButton }
                    }
                }
            }
            .padding(.trailing, isExpanded ? 0 : ChatComposerMetrics.pillInset)
            .padding(.vertical, isExpanded ? 0 : ChatComposerMetrics.pillInset)
        }
        .padding(.top, isExpanded ? 2 : 0)
        .padding(.bottom, isExpanded ? 4 : 0)
        .modifier(ChatComposerSurfaceStyle(isExpanded: isExpanded))
    }

    private var plusMenu: some View {
        ChatUIKitMenuButton {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial,
                               inheritsClipping: true, in: Circle())
                .clipShape(Circle())
        } menu: {
            UIMenu(children: [UIMenu(title: String(localized: "Attach"), options: [.displayInline], children: [
                attachmentAction(.files, title: String(localized: "Attach File"), image: "paperclip"),
                attachmentAction(.photos, title: String(localized: "Photos"), image: "photo.on.rectangle"),
                attachmentAction(.camera, title: String(localized: "Camera"), image: "camera")
            ])])
        }
        .tint(Color(.secondaryLabel))
        .disabled(!model.mayImportAttachments || model.attachments.isImporting)
        .accessibilityLabel("Composer options")
    }

    private func attachmentAction(_ choice: BotAttachmentPicker, title: String, image: String) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: image),
                 attributes: choice == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) ? .disabled : []) { _ in
            Task { @MainActor in
                guard model.mayImportAttachments else { return }
                shouldRestoreFocusAfterPicker = isFocused
                isFocused = false
                picker = choice
            }
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

    private var voiceControlButton: some View {
        ComposerVoiceControlButton(
            isListening: voiceInput.isListening,
            isDisabled: isVoiceInputDisabled,
            color: Color(.secondaryLabel),
            isRecordingVoiceNote: false,
            supportsVoiceNotes: false,
            onTap: toggleVoiceInput,
            onRecordingStart: {},
            onRecordingDragChanged: { _ in },
            onRecordingEnd: { _ in }
        )
    }

    private var isVoiceInputDisabled: Bool {
        BotVoiceInputPolicy.isDisabled(
            isListening: voiceInput.isListening,
            isRequestingPermission: voiceInput.isRequestingPermission,
            mayEditDraft: model.mayEditDraft
        )
    }

    private var voiceStatus: ComposerVoiceStatus? {
        switch voiceInput.state {
        case .listening:
            return ComposerVoiceStatus(text: String(localized: "Listening..."), systemImage: "waveform", isError: false)
        case .serverListening:
            return ComposerVoiceStatus(text: String(localized: "Recording..."), systemImage: "mic.fill", isError: false)
        case .transcribing:
            return ComposerVoiceStatus(text: String(localized: "Transcribing..."), systemImage: "waveform", isError: false)
        case .requestingPermission:
            return ComposerVoiceStatus(
                text: String(localized: "Requesting voice permissions..."),
                systemImage: "mic.badge.plus",
                isError: false
            )
        case .idle:
            break
        }

        guard let errorMessage = voiceInput.errorMessage else { return nil }
        return ComposerVoiceStatus(
            text: errorMessage,
            systemImage: "exclamationmark.triangle",
            isError: true
        )
    }

    @MainActor
    private func toggleVoiceInput() {
        let insertionRange = BotVoiceInputPolicy.insertionRange(
            in: model.draft,
            selection: selection.range,
            isFocused: isFocused
        )
        let insertion = BotVoiceDraftInsertion(draft: model.draft, selection: insertionRange)
        voiceInput.apiClient = nil
        voiceInput.providerPreference = .onDeviceOnly
        voiceInput.locale = .current
        Task {
            await voiceInput.toggle(currentDraft: "") { transcript in
                let result = insertion.applying(transcript: transcript)
                model.editDraft(result.draft)
                selection = selection.moved(to: result.selection)
            }
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
            Image(systemName: "arrow.up")
                .font(.system(size: actionIconSize, weight: .semibold))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .background(appearance.background)
                .foregroundStyle(appearance.foreground)
                .clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .disabled(!canSend)
        .accessibilityLabel(Text(mode.title))
        .accessibilityHint(Text(mode.explanation))
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func send() {
        if voiceInput.isListening { voiceInput.stopBeforeSubmittingDraft() }
        guard let action = model.preparePrompt(mode) else { return }
        if mode == .redirect { redirectAction = action }
        else { Task { await model.submit(action) } }
    }
}

/// One dictation run replaces the selection that existed when the mic was tapped.
/// Every partial transcript is applied to that same base draft, so speech updates
/// replace each other instead of accumulating duplicate words.
struct BotVoiceDraftInsertion {
    struct Result: Equatable {
        let draft: String
        let selection: NSRange
    }

    private let draft: NSString
    private let range: NSRange

    init(draft: String, selection: NSRange) {
        self.draft = draft as NSString
        let location = min(max(selection.location, 0), self.draft.length)
        let length = min(max(selection.length, 0), self.draft.length - location)
        range = NSRange(location: location, length: length)
    }

    func applying(transcript: String) -> Result {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return Result(draft: draft as String, selection: range)
        }

        let before = draft.substring(to: range.location)
        let after = draft.substring(from: range.upperBound)
        let leadingSpace = Self.needsLeadingSpace(before: before, transcript: transcript) ? " " : ""
        let trailingSpace = Self.needsTrailingSpace(transcript: transcript, after: after) ? " " : ""
        let replacement = leadingSpace + transcript + trailingSpace
        let updated = draft.replacingCharacters(in: range, with: replacement)
        let caret = range.location + (replacement as NSString).length
        return Result(draft: updated, selection: NSRange(location: caret, length: 0))
    }

    private static func needsLeadingSpace(before: String, transcript: String) -> Bool {
        guard let left = before.unicodeScalars.last, let right = transcript.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(left)
            && !CharacterSet.whitespacesAndNewlines.contains(right)
            && !CharacterSet(charactersIn: "([{“‘").contains(left)
    }

    private static func needsTrailingSpace(transcript: String, after: String) -> Bool {
        guard let left = transcript.unicodeScalars.last, let right = after.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(left)
            && !CharacterSet.whitespacesAndNewlines.contains(right)
            && !CharacterSet.punctuationCharacters.contains(right)
    }
}

enum BotVoiceInputPolicy {
    static func isDisabled(isListening: Bool, isRequestingPermission: Bool, mayEditDraft: Bool) -> Bool {
        if isListening { return false }
        return !mayEditDraft || isRequestingPermission
    }

    /// A collapsed editor has no visible caret, so dictation follows Sessions and
    /// appends. Once focused, the editor's UTF-16 selection is authoritative.
    static func insertionRange(in draft: String, selection: NSRange, isFocused: Bool) -> NSRange {
        isFocused ? selection : NSRange(location: (draft as NSString).length, length: 0)
    }
}

/// Ready and connected has no status chrome. Recovery, work and failures appear
/// immediately above the composer, including the existing Desktop-only actions.
private struct BotChatStatusView: View {
    let model: BotConversation
    let onReconnect: () -> Void
    let onShowRequest: () -> Void

    var body: some View {
        if connectionText != nil || (model.connectionState == .connected && model.turn != .idle) || model.errorMessage != nil
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
                if model.isUploadingAttachments {
                    HStack {
                        Text("Uploading…")
                        Button("Cancel upload") { model.cancelAttachmentUpload() }
                    }
                } else if model.submittingPrompt != nil {
                    Text("Sending…")
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
                if model.connectionState == .disconnected && !model.isReconnecting && model.errorMessage != nil {
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
        guard !model.isReconnecting else { return nil }
        switch model.connectionState {
        case .connected: return nil
        case .recovering: return String(localized: "Loading current conversation…")
        case .disconnected: return nil
        }
    }

    private var turnText: String? {
        switch model.turn {
        case .idle, .needsAttention: return nil
        case .running: return model.workStatus ?? String(localized: "Working")
        case .submitting: return String(localized: "Sending…")
        case .stopping: return String(localized: "Stopping…")
        case .uncertain: return model.uncertainStop ? String(localized: "Outcome unknown") : nil
        case .interrupted: return String(localized: "Work was interrupted. The saved conversation is loaded.")
        case .unknown: return String(localized: "Checking current work…")
        }
    }
}
