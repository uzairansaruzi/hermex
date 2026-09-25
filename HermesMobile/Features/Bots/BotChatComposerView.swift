import SwiftUI
import UIKit

/// Sessions presentation with Bot-owned draft and action rules. The same editor
/// stays mounted through focus changes; no webui runtime controls are involved.
struct BotChatComposerView: View {
    let model: BotConversation
    var mentionAvatars: [String: UIImage] = [:]
    /// Owned by the screen, as in Sessions, so a transcript tap can put the
    /// keyboard away without reaching into the composer.
    @Binding var isFocused: Bool
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
    @State private var selection = ComposerSelection()
    @State private var inputHeight: CGFloat = 22
    @State private var measuredHeight: CGFloat = 0
    @State private var keyboardIsVisible = false
    @State private var voiceInput = ComposerVoiceInputController()

    @State private var settingsPresented = false
    /// Error texts the user tapped away or that timed out. A new error with
    /// different text shows; a dismissed one stays gone until the next send
    /// clears the set, so two lingering errors cannot take turns in the pill.
    @State private var dismissedErrors: Set<String> = []
    /// True while the send-choice card is up: a send landed on a working bot
    /// and the user has not yet said whether it steers, queues or interrupts.
    @State private var choosingSendMode = false

    private var isExpanded: Bool { isFocused || settingsPresented || picker != nil || shouldRestoreFocusAfterPicker || preview != nil || model.submittingPrompt != nil }
    private var showsToolbar: Bool { isExpanded }
    private var showsStop: Bool { model.mayStop || model.turn == .stopping }
    /// Send is one button. Idle, it starts a turn; working, it asks what the
    /// message should do, so it is live whenever any of those is.
    private var canSend: Bool {
        model.hasSendableInput && (model.maySubmit(.send) || !busyChoices.isEmpty)
    }
    private var busyChoices: [BotPromptMode] {
        BotPromptMode.busyChoices(hasAttachments: !model.attachments.items.isEmpty).filter(model.maySubmit)
    }
    private var appearance: ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: false, isDisabled: !canSend, colorScheme: colorScheme,
            tintsPrimaryActions: tintsPrimaryActions, themeHex: themeHex
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            // One floating pill instead of a strip of status lines: only what the
            // user can act on or must know, highest priority first, and never a
            // receipt for work the transcript already shows.
            if let pill {
                BotComposerPillView(pill: pill, onReconnect: onReconnect, onShowRequest: onShowRequest,
                                    onCancelUpload: { model.cancelAttachmentUpload() },
                                    onDismissError: { if let text = pill.errorText { dismissedErrors.insert(text) } })
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
            composerContainer
        }
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: pill)
        // An error the user did not tap away leaves on its own, like the inbox toast.
        .task(id: pill?.errorText) {
            guard let text = pill?.errorText else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            dismissedErrors.insert(text)
        }
        .onChange(of: model.submittingPrompt) { _, submitting in
            if submitting != nil { dismissedErrors = [] }
        }
        // A dismissal covers one occurrence. Once the error's source clears, the
        // same text failing again is news and shows again.
        .onChange(of: errorTexts) { _, current in dismissedErrors.formIntersection(current) }
    }

    /// Every error a pill could carry, in priority order.
    private var errorTexts: [String] {
        [model.errorMessage, model.chatControls.errorMessage, model.attachments.errorMessage,
         voiceInput.errorMessage].compactMap { $0 }
    }

    private var pill: BotComposerPill? {
        BotComposerPill.resolve(
            requestText: model.turn == .needsAttention ? requestText : nil,
            // A request the phone could not read has no card to jump to.
            requestHasCard: model.pendingRequest != nil,
            errorText: errorTexts.first { !dismissedErrors.contains($0) },
            voiceStatus: voiceStatus,
            offersReconnect: model.connectionState == .disconnected && !model.isReconnecting && model.errorMessage != nil,
            isUploading: model.isUploadingAttachments
        )
    }

    /// What the blocked bot is waiting on. "Handling this" is only true where
    /// there is nothing to do: a request the phone can answer or decline has an
    /// action on its card, and saying it is handled would hide that.
    private var requestText: String {
        if model.pendingRequest?.isAnswerable == true { return String(localized: "Waiting for your answer") }
        if model.mayDecline { return String(localized: "Waiting on Hermes Desktop") }
        if model.pendingRequest == nil { return String(localized: "Needs attention. Answer the request in Hermes Desktop on this same connection.") }
        return String(localized: "Hermes Desktop is handling this")
    }

    private var composerContainer: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                if isFocused, model.mayEditDraft { autocomplete }

                composerSurface.padding(.horizontal, 16)

                if showsToolbar {
                    HStack(alignment: .center, spacing: 8) {
                        ComposerToolbarScroller {
                            plusMenu
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
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
        // The card rides the same keyboard-retaining overlay as the "+" picker, so
        // the keyboard stays up and the two cards look and move alike.
        .background {
            HermexKeyboardRetainingOverlay(isPresented: choosingSendMode) {
                BotSendChoiceView(choices: busyChoices, onPick: { mode in
                    choosingSendMode = false
                    guard let action = model.preparePrompt(mode) else { return }
                    Task { await model.submit(action) }
                }, onDismiss: { choosingSendMode = false })
            }
            .frame(width: 0, height: 0)
        }
        // The bot finishing, or the choices changing under the card, closes it:
        // the next send re-asks with the current truth.
        .onChange(of: busyChoices) { _, choices in
            if choices.isEmpty { choosingSendMode = false }
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
    /// wins, so the two can never stack. The skill panel opens even while the
    /// bot works: what the send becomes is decided at send time, and a skill
    /// sent as Steer just reaches the host as text.
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
                            editDraft(result.draft)
                            selection = selection.moved(to: result.selection)
                        },
                        onSelectFile: { match in
                            let result = trigger.applying(
                                match.isDirectory ? "@\(match.path)/" : "@\(match.path) ", to: model.draft
                            )
                            editDraft(result.draft)
                            selection = selection.moved(to: result.selection)
                            if !match.isDirectory { model.recordFileChipReference(match.path) }
                        }
                    )
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .task(id: trigger.query) { await model.searchFilePaths(trigger.query) }
        } else if let trigger = BotSlashTrigger.detect(in: model.draft, selection: selection.range) {
            let matches = SlashSkillFormatter.matching(trigger.query, in: model.slashSkills)
            if !matches.isEmpty {
                BotSlashAutocompleteView(suggestions: matches) { skill in
                    // The slug, exactly as Sessions completes a skill: it is what
                    // `ComposerChipCatalog` is keyed by, so the chip draws. The send
                    // path resolves it back to the host's own key before dispatch.
                    let result = trigger.applying("/" + skill.slashName + " ", to: model.draft)
                    editDraft(result.draft)
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
                    text: Binding(get: { model.draft }, set: editDraft),
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
        Button {
            guard model.mayImportAttachments,
                  model.attachments.items.count < HermexAttachmentPickerPolicy.maximumBotAttachments
            else { return }
            shouldRestoreFocusAfterPicker = isFocused
            picker = .photos
        } label: {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: ChatComposerMetrics.actionSize, height: ChatComposerMetrics.actionSize)
                .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial,
                               inheritsClipping: true, in: Circle())
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(Color(.secondaryLabel))
        .disabled(
            !model.mayImportAttachments
                || model.attachments.isImporting
                || model.attachments.items.count >= HermexAttachmentPickerPolicy.maximumBotAttachments
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composer options")
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
            return nil
        }
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
                guard let result = insertion.applying(transcript: transcript, to: model.draft) else {
                    voiceInput.stopBeforeSubmittingDraft()
                    return
                }
                model.editDraft(result.draft)
                selection = selection.moved(to: result.selection)
            }
        }
    }

    private func editDraft(_ text: String) {
        if voiceInput.isListening || voiceInput.isRequestingPermission {
            voiceInput.stopBeforeSubmittingDraft()
        }
        model.editDraft(text)
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
        .accessibilityLabel(Text("Send"))
        .keyboardShortcut(.return, modifiers: .command)
    }

    /// Idle sends go straight out. On a working bot the message could steer,
    /// queue or interrupt, and that is the user's call every time, so the card
    /// asks before anything is written.
    private func send() {
        voiceInput.stopBeforeSubmittingDraft()
        guard model.hasSendableInput else { return }
        if let action = model.preparePrompt(.send) {
            Task { await model.submit(action) }
        } else if !busyChoices.isEmpty {
            choosingSendMode = true
        }
    }
}

/// One dictation run replaces the selection that existed when the mic was tapped.
/// Every partial transcript is applied to that same base draft, so speech updates
/// replace each other instead of accumulating duplicate words.
final class BotVoiceDraftInsertion {
    struct Result: Equatable {
        let draft: String
        let selection: NSRange
    }

    private let draft: NSString
    private let range: NSRange
    private var lastAppliedDraft: String

    init(draft: String, selection: NSRange) {
        self.draft = draft as NSString
        lastAppliedDraft = draft
        let location = min(max(selection.location, 0), self.draft.length)
        let length = min(max(selection.length, 0), self.draft.length - location)
        range = NSRange(location: location, length: length)
    }

    func applying(transcript: String, to currentDraft: String) -> Result? {
        guard currentDraft == lastAppliedDraft else { return nil }
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
        lastAppliedDraft = updated
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

/// The one thing worth a pill above the composer, highest priority first. A
/// request outranks an error because it has somewhere to go; an error outranks
/// recovery because the user can read it; upload comes last because Cancel is
/// only useful while nothing else is wrong.
enum BotComposerPill: Equatable {
    /// A blocking request with a card in the transcript to jump to.
    case request(String)
    /// A blocking request the phone cannot show; the line is the whole message.
    case notice(String)
    case error(String)
    case voice(ComposerVoiceStatus)
    case reconnect
    case uploading
    case retrySend

    static func resolve(requestText: String?, requestHasCard: Bool, errorText: String?, voiceStatus: ComposerVoiceStatus?,
                        offersReconnect: Bool, isUploading: Bool) -> BotComposerPill? {
        if let requestText { return requestHasCard ? .request(requestText) : .notice(requestText) }
        if let errorText { return .error(errorText) }
        if let voiceStatus { return .voice(voiceStatus) }
        if offersReconnect { return .reconnect }
        if isUploading { return .uploading }
        return nil
    }

    var errorText: String? { if case .error(let text) = self { return text }; return nil }

    /// Rooms share the action pill, but their host exposes no turn start time.
    /// Routine working/connecting states stay quiet; requests and recovery remain reachable.
    static func room(link: BotRoomReader.Link, blocked: Bool, hasActions: Bool,
                     mayRetry: Bool, errorText: String?) -> BotComposerPill? {
        if let errorText { return .error(errorText) }
        if link == .stopped { return .reconnect }
        if mayRetry { return .retrySend }
        if link == .live && blocked {
            return hasActions ? .request(String(localized: "Waiting for your answer"))
                : .notice(String(localized: "Waiting on Hermes Desktop"))
        }
        return nil
    }
}

/// One centered capsule with material and no motion of its own. Request and
/// Reconnect are buttons; an error is tappable to dismiss; Uploading carries Cancel.
struct BotComposerPillView: View {
    let pill: BotComposerPill
    let onReconnect: () -> Void
    let onShowRequest: () -> Void
    let onCancelUpload: () -> Void
    let onDismissError: () -> Void
    var onRetrySend: () -> Void = {}

    var body: some View {
        Group {
            switch pill {
            case .request(let text):
                Button(action: onShowRequest) { Label(text, systemImage: "arrow.down.circle") }
            case .notice(let text):
                Label(text, systemImage: "exclamationmark.circle")
            case .error(let text):
                Button(action: onDismissError) { Label(text, systemImage: "exclamationmark.triangle") }
                    .accessibilityHint(Text("Dismisses this message"))
            case .voice(let status):
                Label(status.text, systemImage: status.systemImage)
            case .reconnect:
                Button(action: onReconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
            case .retrySend:
                Button(action: onRetrySend) { Label("Retry send", systemImage: "arrow.up") }
            case .uploading:
                HStack(spacing: 12) {
                    Label("Uploading…", systemImage: "arrow.up.doc")
                    Button("Cancel", action: onCancelUpload).fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
        .font(AppFont.footnote())
        .lineLimit(3)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("bot-chat-status")
    }
}

/// The send-choice card: the "+" picker's chrome (scrim, material panel, the
/// same present and dismiss motion) holding Steer, Queue and Interrupt. It sits
/// bottom-trailing, by the send button that opened it.
struct BotSendChoiceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isVisible = false
    @State private var isDismissing = false
    @State private var transitionTask: Task<Void, Never>?

    let choices: [BotPromptMode]
    let onPick: (BotPromptMode) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: proxy.size.width)
            ZStack(alignment: .bottomTrailing) {
                Button(action: dismiss) {
                    Color.black.opacity(isVisible ? 0.08 : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDismissing)
                .accessibilityLabel("Close send choices")

                VStack(spacing: 0) {
                    ForEach(choices, id: \.self) { choice in
                        HermexAttachmentMenuRow(title: Text(choice.title), systemImage: choice.systemImage) {
                            finish { onPick(choice) }
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(width: width)
                .modifier(HermexAttachmentPanelSurface(reduceTransparency: reduceTransparency))
                .compositingGroup()
                .clipShape(.rect(cornerRadius: 46, style: .continuous))
                .padding(.trailing, HermexAttachmentPickerLayoutMetrics.menuLeadingPadding)
                .padding(.bottom, 74)
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(isVisible ? 1 : 0.96, anchor: .bottomTrailing)
                .offset(y: isVisible ? 0 : 8)
                .allowsHitTesting(!isDismissing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Send choices")
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .onAppear(perform: present)
        .onDisappear { transitionTask?.cancel(); transitionTask = nil }
    }

    private func present() {
        guard !isVisible else { return }
        guard !reduceMotion else { isVisible = true; return }
        transitionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { isVisible = true }
            transitionTask = nil
        }
    }

    private func dismiss() { finish(onDismiss) }

    /// Fades the card out, then hands control back; a pick and a dismissal
    /// leave the same way.
    private func finish(_ completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        transitionTask?.cancel()
        guard !reduceMotion else { completion(); return }
        withAnimation(.easeInOut(duration: 0.16)) { isVisible = false }
        transitionTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled else { return }
            completion()
        }
    }
}
