import SwiftUI
import UIKit

struct ComposerRetryableStatus {
    let message: String
    let onRetry: () -> Void
}

private struct ComposerStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let text: String
    let isError: Bool
    let onRetry: (() -> Void)?
    let fixPrompt: String?
    let onCancel: (() -> Void)?
    let onFix: (() -> Void)?
    let onDismiss: (() -> Void)?
    @State private var didCopyFixPrompt = false

    var body: some View {
        let layout = fixPrompt != nil && dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            Text(text)
                .font(AppFont.caption())
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.borderless)
            }

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.borderless)
            }

            if let onFix {
                Button("Fix on This Phone", action: onFix)
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.borderless)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fixPrompt {
                fixPromptButton(fixPrompt)
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(textColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .onChange(of: text) { didCopyFixPrompt = false }
    }

    private func fixPromptButton(_ prompt: String) -> some View {
        Button {
            UIPasteboard.general.string = prompt
            didCopyFixPrompt = true
            AccessibilityNotification.Announcement(String(localized: "Fix prompt copied")).post()
        } label: {
            if didCopyFixPrompt {
                Label("Copied", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else {
                Text("Copy fix prompt")
            }
        }
        .font(AppFont.caption(weight: .semibold))
        .buttonStyle(.borderless)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(didCopyFixPrompt ? Text("Fix prompt copied") : Text("Copy fix prompt"))
        .accessibilityHint(Text("Copies a prompt that asks your Hermes agent to restart Hermes WebUI."))
    }

    private var textColor: Color {
        isError ? Color(.appText) : Color(.appTextSecondary)
    }

    private var backgroundColor: Color {
        isError ? Color.red.opacity(0.08) : Color(.appSurface)
    }

    private var borderColor: Color {
        isError ? Color.red.opacity(0.25) : Color(.appSeparator).opacity(0.25)
    }
}

private struct ComposerQuoteDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let quote: ComposerQuote
    let onRemove: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: quote.text)
                    .font(AppFont.body())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .themedPageBackground()
            .navigationTitle("Quoted passage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove Quote", role: .destructive, action: onRemove)
                }
            }
        }
    }
}

struct MessageComposerView: View {
    @Environment(\.composerViewportIsShort) private var viewportIsShort
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(AppAppearanceSettings.accentHexKey) private var accentHex: String?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var plusIconSize: CGFloat = 20

    private let circleSize = ChatComposerMetrics.actionSize
    private let pillInset = ChatComposerMetrics.pillInset

    @Binding var draftMessage: String
    @Binding var quotes: [ComposerQuote]
    @Binding var isFocused: Bool
    let isSending: Bool
    let isCompressingSession: Bool
    let isWaitingForStream: Bool
    let isCancellingStream: Bool
    let access: ChatComposerAccess
    let errorMessage: String?
    let errorFixPrompt: String?
    let onFixError: (() -> Void)?
    let configurationErrorMessage: String?
    let contextWindowSnapshot: ContextWindowSnapshot?
    let gitViewModel: GitWorkspaceAvailabilityViewModel
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let selectedModelTitle: String
    let workspaceRoots: [WorkspaceRoot]
    let selectedWorkspacePath: String?
    let workspaceSuggestions: [String]
    let workspaceManagementServer: URL?
    let personalitySuggestions: [String]
    let skillSuggestions: [SkillSlashSuggestion]
    let hasLoadedSkillSuggestions: Bool
    let agentCommands: [AgentCommand]
    let profileOptions: [ProfileSummary]
    let isSingleProfileMode: Bool
    let selectedProfileName: String?
    let selectedProfileTitle: String
    let selectedReasoningEffort: String?
    let supportedReasoningEfforts: [String]?
    let supportsReasoningEffort: Bool?
    let showsReasoningControl: Bool
    let isUpdatingConfiguration: Bool
    let pendingAttachments: [PendingAttachment]
    let isUploadingAttachment: Bool
    let attachmentUploadCount: Int
    let attachmentUploadGeneration: Int
    let isSendingVoiceNote: Bool
    let autoStartsVoiceInput: Bool
    let apiClient: APIClient?
    let sessionID: String?
    let server: URL
    let searchFilePaths: ((String) async -> Void)?
    let chipFilePaths: Set<String>
    var botMentions: BotMentions? = nil
    var mentionAvatars: [String: UIImage] = [:]
    let filePathSearch: ComposerFilePathSearch
    let uploadAttachmentErrorMessage: String?
    let steerFailure: ComposerRetryableStatus?
    let streamingSendBehavior: StreamingSendBehavior
    let onSend: (StreamingSendBehavior?) -> Void
    let onSendVoiceNote: (Data, String) -> Void
    let onCancel: () -> Void
    let onSelectModel: (ModelCatalogOption) -> Void
    let onModelPickerOpen: () async -> Void
    let onSelectReasoningEffort: (String) async -> Bool
    let onLoadWorkspaceSuggestions: (String) async -> Void
    let onWorkspaceRegistryChanged: () async -> Void
    let onLoadPersonalitySuggestions: () async -> Void
    let onLoadSkillSuggestions: () async -> Void
    let onSelectWorkspace: (String) async -> Void
    let onSelectProfile: (ProfileSummary) -> Void
    let onHeightChange: (_ height: CGFloat, _ isResting: Bool) -> Void
    let onPhotoMediaSelected: ([HermexPickedMedia]) -> Void
    let onFileURLsSelected: ([URL]) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPreviewAttachment: (PendingAttachment) -> Void
    let onDismissUploadAttachmentError: () -> Void
    let onDismissError: (() -> Void)?
    let onSelectFileReference: (String) -> Void
    let onFileReferenceCandidatesChange: (String) async -> Void
    let onDraftEdit: (String) -> Void
    var recallLastSentText: (() -> String?)? = nil
    var onPasteLargeText: ((String) -> Void)? = nil
    let onOpenFileReference: (String) -> Void
    let onSelectGitBranch: (GitCheckoutTarget) -> Void
    let onCreateGitBranch: (GitCheckoutTarget) -> Void
    let onRefreshGitBranches: () -> Void
    var showsSessionControls = true
    var slashScope = SlashCommandScope.webui
    var hostSlashCompletion: HermesSlashCompletion?
    var onCompleteHostSlashArgument: (String?) async -> Void = { _ in }
    var showsModelAndProfileControls = false
    var configurationNotice: String?
    var sentReasoningEffort: String?
    var fastMode: Bool?
    var mayChangeFastMode = false
    var onSelectFastMode: (Bool) -> Void = { _ in }
    var isChatSettingsPresented: Binding<Bool> = .constant(false)
    var isModelSettingsPresented: Binding<Bool> = .constant(false)
    var modelConfirmationControls: BotChatControls?
    var approvals: ComposerApprovals?
    var onSetYolo: (Bool) -> Void = { _ in }
    var onSelectApprovalMode: (HermesApprovalMode) -> Void = { _ in }
    var showsNewChatControls = false
    var uploadsAttachmentsOnSend = false
    var onCancelAttachmentUpload: (() -> Void)?
    var hermesTranscriber: ComposerTranscriber?

    @State private var textFieldHeight: CGFloat = 0
    @State private var textInputHeight: CGFloat = 22
    @State private var composerSelection = ComposerSelection()
    @State private var dismissedSuggestionsAnchor: SuggestionAnchor?
    @State private var noticeMessage: String?
    @State private var showsWorkspaceSheet = false
    @State private var showsGitBranchPicker = false
    @State private var afterChatSettingsDismiss: (() -> Void)?
    @State private var optimisticWorkspacePath: String?
    @State private var favoriteModelKeys: [ModelFavoriteKey] = []
    @State private var recentModelKeys: [ModelFavoriteKey] = []
    @State private var keyboardIsVisible = false
    @State private var isCardOpen = false
    @State private var cardFallback: DispatchWorkItem?
    @State private var shouldRestoreFocusAfterPresentation = false
    @State private var selectedQuote: ComposerQuote?
    @State private var choosingSendBehavior = false
    @State private var sendHold = ChatComposerSendHold()
    @State private var sendHoldWorkItem: DispatchWorkItem?
    @GestureState private var isPressingSend = false

    @State private var deferredUploadFocusPhase: DeferredUploadFocusPhase = .none
    @State private var showMediaPicker = false
    @State private var presentFilesAfterMediaPickerDismisses = false
    @State private var showFileImporter = false
    @State private var voiceInput = ComposerVoiceInputController()
    @State private var restoresFocusAfterDictation = false
    @State private var voiceNoteRecorder = ComposerVoiceNoteRecorder()
    @State private var voiceNoteCancelArmed = false
    @State private var voiceNoteIsHeld = true
    @State private var didAutoStartVoiceInput = false
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    private var isReadOnly: Bool {
        !access.allowsEditing
    }

    private var holdsHostControls: Bool {
        !access.allowsHostControls
    }

    private enum DeferredUploadFocusPhase: Equatable {
        case none
        case waitingForUploadStart(afterGeneration: Int)
        case waitingForUploadsToFinish
    }

    private var slashTrigger: ComposerSlashTrigger? {
        guard !areSuggestionsDismissed else { return nil }
        return ComposerSlashTrigger.detect(in: draftMessage, selection: composerSelection.range, scope: slashScope)
    }

    private struct SuggestionAnchor: Equatable {
        let draft: String
        let caret: NSRange
    }

    private var areSuggestionsDismissed: Bool {
        isDictating || dismissedSuggestionsAnchor == SuggestionAnchor(draft: draftMessage, caret: composerSelection.range)
    }

    private var hostSlashArgumentText: String? {
        guard !holdsHostControls, fileTrigger == nil, let trigger = slashTrigger, trigger.startsDraft,
              ParsedSlashQuery(query: trigger.text, scope: slashScope).isHostArgumentMode else { return nil }
        return trigger.text
    }

    private var fileTrigger: ComposerFileTrigger? {
        guard !holdsHostControls, !areSuggestionsDismissed, searchFilePaths != nil || botMentions != nil else {
            return nil
        }
        return ComposerFileTrigger.detect(in: draftMessage, selection: composerSelection.range)
    }

    private var showsFileAutocomplete: Bool {
        fileTrigger != nil
    }

    private var slashQuery: String? {
        guard fileTrigger == nil else { return nil }
        return slashTrigger?.panelQuery(scope: slashScope, skills: skillSuggestions,
                                        hasLoadedSkills: hasLoadedSkillSuggestions, hostCompletion: hostSlashCompletion)
    }

    private var showsSlashAutocomplete: Bool {
        slashQuery != nil
    }

    private var showsSlashAutocompleteSkillsOnly: Bool {
        !(slashTrigger?.startsDraft ?? true)
    }

    private func editDraft(_ text: String) {
        draftMessage = text
        onDraftEdit(text)
    }

    private func applyCompletion(_ replacement: String) {
        guard let trigger = slashTrigger else { return }

        let completed = trigger.applying(replacement, to: draftMessage)
        editDraft(completed.draft)
        composerSelection = composerSelection.moved(to: completed.selection)
    }

    private func pickCompletion(_ replacement: String) {
        applyCompletion(replacement)
        ChatHaptics.autocompleteAccepted(isEnabled: isHapticsEnabled)
    }

    private func botAutocomplete(_ trigger: ComposerFileTrigger, mentions: BotMentions) -> some View {
        let bots = mentions.completions(query: trigger.query)
        return Group {
            if !bots.isEmpty || !filePathSearch.matches.isEmpty || filePathSearch.isLoading {
                BotAtAutocompleteView(
                    botCompletions: bots, avatars: mentionAvatars,
                    fileMatches: filePathSearch.matches, isLoadingFiles: filePathSearch.isLoading,
                    onSelectBot: { item in
                        let completed = trigger.applying("@" + item.tag + " ", to: draftMessage)
                        editDraft(completed.draft)
                        composerSelection = composerSelection.moved(to: completed.selection)
                        ChatHaptics.autocompleteAccepted(isEnabled: isHapticsEnabled)
                    },
                    onSelectFile: applyFileCompletion
                )
                .padding(.horizontal)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
        .task(id: trigger.query) { await searchFilePaths?(trigger.query) }
    }

    private func applyFileCompletion(_ match: ComposerFilePathSearch.Match) {
        guard let trigger = fileTrigger else { return }

        let completed = trigger.applying(
            match.isDirectory ? "@\(match.path)/" : "@\(match.path) ",
            to: draftMessage
        )
        editDraft(completed.draft)
        composerSelection = composerSelection.moved(to: completed.selection)

        if !match.isDirectory {
            onSelectFileReference(match.path)
        }
        ChatHaptics.autocompleteAccepted(isEnabled: isHapticsEnabled)
    }

    private var parsedSlashQuery: ParsedSlashQuery {
        ParsedSlashQuery(query: slashQuery ?? "", scope: slashScope)
    }

    private var slashAutocompleteLoadKey: String {
        guard showsSlashAutocomplete,
              let command = parsedSlashQuery.command
        else {
            return showsSlashAutocomplete ? "skills" : ""
        }

        guard parsedSlashQuery.isSubArgMode else {
            return "skills"
        }

        switch command.subArgs {
        case .workspaces:
            return "workspace:\(parsedSlashQuery.argQuery)"
        case .personalities:
            return "personalities"
        case .skills:
            return "skills"
        case .models, .reasoningLevels, .goalActions, .none:
            return ""
        }
    }

    private var composerWithLifecycle: some View {
        VStack(spacing: 6) {
            if voiceNoteRecorder.isRecording {
                ComposerVoiceRecordingBar(
                    elapsed: voiceNoteRecorder.elapsed,
                    isCancelArmed: voiceNoteCancelArmed,
                    isHeld: voiceNoteIsHeld,
                    onStop: { finishVoiceNote(translationHeight: 0) },
                    onCancel: cancelVoiceNote
                )
                .padding(.horizontal, 16)
            } else if let voiceNoteStatus {
                ComposerVoiceStatusView(status: voiceNoteStatus)
            } else if let voiceStatus {
                ComposerVoiceStatusView(status: voiceStatus, onDismiss: voiceInput.dismissError)
            } else if let composerStatus {
                ComposerStatusView(
                    text: composerStatus.text,
                    isError: composerStatus.isError,
                    onRetry: composerStatus.onRetry,
                    fixPrompt: composerStatus.fixPrompt,
                    onCancel: composerStatus.onCancel,
                    onFix: composerStatus.onFix,
                    onDismiss: composerStatus.onDismiss
                )
            }

            Group {
                if let fileTrigger, let botMentions {
                    botAutocomplete(fileTrigger, mentions: botMentions)
                } else if let fileTrigger, let searchFilePaths {
                    FilePathAutocompleteView(
                        query: fileTrigger.query,
                        search: filePathSearch,
                        load: searchFilePaths,
                        onSelect: applyFileCompletion
                    )
                    .padding(.horizontal)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                } else if let slashQuery {
                    SlashCommandAutocompleteView(
                        query: slashQuery,
                        selectedModelID: selectedModelID,
                        modelGroups: modelGroups,
                        workspaceRoots: workspaceRoots,
                        workspaceSuggestions: workspaceSuggestions,
                        personalitySuggestions: personalitySuggestions,
                        skillSuggestions: skillSuggestions,
                        agentCommands: agentCommands,
                        skillsOnly: showsSlashAutocompleteSkillsOnly,
                        selectedReasoningEffort: selectedReasoningEffort,
                        scope: slashScope,
                        reasoningLevels: slashScope.isHermes
                            ? supportedReasoningEfforts ?? [] : SlashCommandCatalog.reasoningLevels,
                        hostCompletion: hostSlashCompletion,
                        onSelectCommand: { command in
                            pickCompletion("/\(command.name) ")
                        },
                        onSelectSkillCommand: { skill in
                            pickCompletion("/\(skill.slashName) ")
                        },
                        onSelectAgentCommand: { command in
                            pickCompletion("/\(command.name) ")
                        },
                        onSelectSkillSubArg: { skill in
                            pickCompletion("/skills \(skill.slashName) ")
                        },
                        onSelectSubArg: { subArg in
                            pickCompletion("/\(parsedSlashQuery.commandName) \(subArg)")
                        },
                        onSelectHostArgument: { item in
                            if let completion = hostSlashCompletion, let trigger = slashTrigger,
                               completion.applies(to: trigger.text) {
                                pickCompletion(completion.applying(item))
                            }
                        }
                    )
                    .padding(.horizontal)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsSlashAutocomplete)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsFileAutocomplete)
            .layoutPriority(-1)

            if showsNewChatControls, showsConfigurationControls, !viewportIsShort {
                newChatControlsRow
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            composerSurface
                .padding(.horizontal)
                .zIndex(1)

            if isExpanded {
                Group {
                    if isDictating {
                        dictationRow.transition(.opacity)
                    } else {
                        toolbarRow.transition(.asymmetric(
                            insertion: .opacity.animation(reduceMotion ? nil : .easeIn(duration: 0.12).delay(0.14)),
                            removal: .opacity
                        ))
                    }
                }
                    .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: isDictating)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(.appCanvas)
                            .padding(.top, -10)
                            .padding(.bottom, -12)
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .transition(.opacity)
            }
        }
        .animation(isExpanded ? ChatMotion.keyboard(reduceMotion: reduceMotion)
            : ChatMotion.composerChrome(reduceMotion: reduceMotion), value: isExpanded)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onHeightChange(proxy.size.height, isResting)
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        onHeightChange(newHeight, isResting)
                    }
            }
        )
        .background {
            HermexKeyboardRetainingOverlay(isPresented: showMediaPicker) {
                HermexAttachmentPickerView(
                    imageCapacity: HermexAttachmentPickerPolicy.availableCapacity(
                        existingCount: pendingAttachments.count,
                        maximum: uploadsAttachmentsOnSend
                            ? HermexAttachmentPickerPolicy.maximumBotAttachments
                            : HermexAttachmentPickerPolicy.maximumSessionImages
                    ),
                    onChooseFiles: {
                        presentFilesAfterMediaPickerDismisses = true
                    },
                    onRecordVoiceNote: isVoiceNoteRecordingDisabled ? nil : { startVoiceNoteRecording(isHeld: false) },
                    onAdd: { media in
                        guard !media.isEmpty else { return }
                        deferFocusRestoreUntilUploadCompletes()
                        onPhotoMediaSelected(media)
                    },
                    onDismiss: {
                        showMediaPicker = false
                    }
                )
            }
            .frame(width: 0, height: 0)
        }
        .background {
            HermexKeyboardRetainingOverlay(isPresented: choosingSendBehavior) {
                SendChoiceCard(
                    choices: sendChoices,
                    onPick: pickSendBehavior,
                    onDismiss: closeSendChoices
                )
            }
            .frame(width: 0, height: 0)
        }
        .onChange(of: sendChoices) { _, choices in
            guard choices.isEmpty else { return }
            cancelScheduledSendChoices()
            closeSendChoices()
        }
        .onChange(of: areSuggestionsDismissed) { _, dismissed in
            if !dismissed { dismissedSuggestionsAnchor = nil }
        }
        .onChange(of: isPressingSend) { _, isPressing in
            if isPressing {
                scheduleSendChoices()
            } else {
                cancelScheduledSendChoices()
            }
        }
        .task(id: [draftMayReferenceSkill, access.isOffline]) {
            await loadSkillSuggestionsForChipsIfNeeded()
        }
        .task(id: ComposerChipTokenizer.fileReferenceCandidates(in: draftMessage)) {
            await onFileReferenceCandidatesChange(draftMessage)
        }
        .task(id: [slashAutocompleteLoadKey, access.isOffline ? "offline" : ""]) {
            await loadSlashAutocompleteSubArgsIfNeeded()
        }
        .task(id: hostSlashArgumentText) {
            await onCompleteHostSlashArgument(hostSlashArgumentText)
        }
        .task(id: AppLock.shared.isLocked) {
            if AppLock.shared.isLocked { voiceInput.suspend() }
            else if scenePhase == .active { voiceInput.resume() }
            autoStartVoiceInputIfNeeded()
        }
        .onChange(of: sessionID) { _, _ in
            restoresFocusAfterDictation = false
            voiceInput.stopBeforeSubmittingDraft()
        }
        .onChange(of: isDictating) { _, isDictating in
            if !isDictating { restoreFocusAfterDictation() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                voiceInput.suspend()
                cancelVoiceNote()
            } else {
                voiceInput.resume()
                autoStartVoiceInputIfNeeded()
            }
        }
        .onChange(of: voiceNoteRecorder.elapsed) { _, elapsed in
            if voiceNoteRecorder.isRecording, elapsed >= ComposerVoiceNoteRecorder.maximumDuration {
                finishVoiceNote(translationHeight: 0)
            }
        }
        .onChange(of: showsGitBranchPicker) { _, isPresented in
            if isPresented {
                prepareForComposerPresentation()
            } else {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: showMediaPicker) { _, isPresented in
            guard !isPresented else { return }
            guard presentFilesAfterMediaPickerDismisses else {
                if !showFileImporter { restoreFocusAfterPresentationDismissalSettles() }
                return
            }
            presentFilesAfterMediaPickerDismisses = false
            prepareForComposerPresentation()
            Task { @MainActor in
                await Task.yield()
                showFileImporter = true
            }
        }
    }

    var body: some View {
        composerWithLifecycle
        .sheet(isPresented: isModelSettingsPresented, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            modelSettingsSheet
        }
        .onChange(of: isModelSettingsPresented.wrappedValue) { _, isPresented in
            if isPresented { prepareForComposerPresentation() }
        }
        .sheet(isPresented: $showsWorkspaceSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            workspacePickerSheet()
        }
        .sheet(isPresented: isChatSettingsPresented, onDismiss: chatSettingsDidDismiss) {
            chatSettingsSheet
        }
        .onChange(of: isChatSettingsPresented.wrappedValue) { _, isPresented in
            if isPresented { prepareForComposerPresentation() }
        }
        .sheet(item: $selectedQuote, onDismiss: restoreFocusAfterPresentationIfNeeded) { quote in
            ComposerQuoteDetailView(
                quote: quote,
                onRemove: {
                    removeQuote(quote.id)
                    selectedQuote = nil
                }
            )
            .themedPageBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                if !urls.isEmpty {
                    deferFocusRestoreUntilUploadCompletes()
                }
                onFileURLsSelected(urls)
            case let .failure(error):
                if isFileImporterCancellation(error) {
                    restoreFocusAfterPresentationDismissalSettles()
                    return
                }

                shouldRestoreFocusAfterPresentation = false
                deferredUploadFocusPhase = .none
                noticeMessage = error.localizedDescription
            }
        }
        .alert(
            "Composer Option",
            isPresented: Binding(
                get: { noticeMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        noticeMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                noticeMessage = nil
            }
        } message: {
            Text(noticeMessage ?? "")
        }
        .onChange(of: selectedWorkspacePath) { _, newValue in
            if optimisticWorkspacePath == newValue {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: isUpdatingConfiguration) { _, isUpdating in
            if !isUpdating {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: configurationErrorMessage) { _, newValue in
            if newValue != nil {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: showFileImporter) { _, isPresented in
            if !isPresented {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: attachmentUploadGeneration) { _, newGeneration in
            handleDeferredUploadStart(newGeneration)
        }
        .onChange(of: attachmentUploadCount) { _, newCount in
            handleDeferredUploadCountChange(newCount)
        }
        .onChange(of: uploadAttachmentErrorMessage) { _, newValue in
            if newValue != nil {
                deferredUploadFocusPhase = .none
            }
        }
        .onAppear { isCardOpen = isFocused }
        .onChange(of: isFocused) { _, focused in
            cardFallback?.cancel()
            guard focused else {
                isCardOpen = false
                return
            }
            if keyboardIsVisible {
                isCardOpen = true
            } else {
                let fallback = DispatchWorkItem { isCardOpen = isFocused }
                cardFallback = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: fallback)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
            cardFallback?.cancel()
            if isFocused { isCardOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
        .onAppear {
            favoriteModelKeys = ModelFavoritesStore(server: server).favoriteKeys
            recentModelKeys = ModelRecentsStore(server: server).recentKeys
        }
        .onDisappear {
            restoresFocusAfterDictation = false
            voiceInput.stopBeforeSubmittingDraft()
            cancelVoiceNote()
            cancelScheduledSendChoices()
            cardFallback?.cancel()
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
        .animation(ChatMotion.keyboard(reduceMotion: reduceMotion), value: keyboardIsVisible)
    }

    private var isResting: Bool {
        !isExpanded && !voiceNoteRecorder.isRecording && voiceNoteStatus == nil && voiceStatus == nil
            && composerStatus == nil
    }

    private var isExpanded: Bool {
        isCardOpen
            || isDictating
            || !quotes.isEmpty
            || shouldRestoreFocusAfterPresentation
    }

    private var isDictating: Bool {
        voiceInput.state != .idle
    }

    private var composerSurface: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ComposerAttachmentStripView(
                    attachments: pendingAttachments,
                    onRemove: onRemoveAttachment,
                    onPreview: onPreviewAttachment
                )
                .transition(.opacity)
            }

            HStack(alignment: .center, spacing: 4) {
                if !isExpanded {
                    plusButton(usesGlass: false)
                }

                ComposerTextInputView(
                    text: Binding(get: { draftMessage }, set: editDraft),
                    selection: $composerSelection,
                    isFocused: $isFocused,
                    inputHeight: $textInputHeight,
                    measuredHeight: $textFieldHeight,
                    isDisabled: isReadOnly,
                    isCollapsed: !isExpanded,
                    keyboardCommands: keyboardCommands,
                    verticalPadding: 12,
                    chipSkills: skillSuggestions,
                    chipFilePaths: chipFilePaths,
                    chipBots: botMentions?.chipReferences(avatars: mentionAvatars) ?? [:],
                    quotes: quotes,
                    onPasteFileProviders: onPasteFileProviders,
                    onPasteFileURLs: onPasteFileURLs,
                    onPasteImageProviders: onPasteImageProviders,
                    onPasteImages: onPasteImages,
                    onTapChip: { token in
                        guard let path = token.filePath else { return }
                        onOpenFileReference(path)
                    },
                    onTapQuote: presentQuote,
                    onRemoveQuote: removeQuote,
                    recallLastSentText: recallLastSentText,
                    onPasteLargeText: onPasteLargeText,
                    collapsedHorizontalPadding: 4
                )
                .allowsHitTesting(!isDictating)

                if !isExpanded {
                    ComposerAttachmentPillPreview(
                        attachments: pendingAttachments,
                        onPreview: onPreviewAttachment
                    )

                    if showsConfigurationControls {
                        modelEffortControl(showsTitle: false)
                    }

                    voiceControlButton

                    actionButton
                }
            }
            .padding(.horizontal, isExpanded ? 0 : pillInset)
            .padding(.vertical, isExpanded ? 0 : pillInset)
        }
        .padding(.top, isExpanded ? 2 : 0)
        .padding(.bottom, isExpanded ? 4 : 0)
        .modifier(ChatComposerSurfaceStyle(isExpanded: isExpanded))
    }

    private var toolbarRow: some View {
        HStack(alignment: .center, spacing: 8) {
            plusButton(usesGlass: true)

            if showsConfigurationControls {
                modelEffortControl(showsTitle: true)
            }

            Spacer(minLength: 0)

            voiceControlButton

            actionButton
        }
    }

    private var newChatControlsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            workspaceSelector

            gitBranchPicker

            profileSelector(onSelect: onSelectProfile)

            Spacer(minLength: 0)
        }
    }

    private var showsConfigurationControls: Bool {
        showsSessionControls || showsModelAndProfileControls
    }

    private var chatSettingsSheet: some View {
        ChatSettingsSheet(
            workspaceTitle: workspaceTitle,
            isWorkspaceDisabled: isConfigurationControlDisabled,
            profileNote: showsSessionControls || isSingleProfileMode
                ? nil : String(localized: "Choosing another starts a new chat in it"),
            contextSnapshot: contextWindowSnapshot,
            workspacePicker: { workspacePickerSheet(perform: closeChatSettings(then:)) },
            profileControl: {
                profileSelector { profile in closeChatSettings { onSelectProfile(profile) } }
            }
        )
    }

    private func closeChatSettings(then action: @escaping () -> Void) {
        afterChatSettingsDismiss = action
        isChatSettingsPresented.wrappedValue = false
    }

    private func chatSettingsDidDismiss() {
        restoreFocusAfterPresentationIfNeeded()
        afterChatSettingsDismiss?()
        afterChatSettingsDismiss = nil
    }

    private func workspacePickerSheet(
        perform: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> some View {
        ComposerWorkspacePickerSheet(
            allowsCustomPath: !showsSessionControls,
            workspaceRoots: workspaceRoots,
            selectedWorkspacePath: displayedWorkspacePath,
            suggestions: workspaceSuggestions,
            managementServer: holdsHostControls ? nil : workspaceManagementServer,
            onLoadSuggestions: onLoadWorkspaceSuggestions,
            onSelect: { path in
                guard !holdsHostControls else { return }
                optimisticWorkspacePath = path
                showsWorkspaceSheet = false
                perform { Task { await onSelectWorkspace(path) } }
            },
            onRegistryChanged: onWorkspaceRegistryChanged
        )
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var dictationRow: some View {
        let finish = actionAppearance(isStop: false, isDisabled: false)
        return ComposerDictationRow(
            voiceInput: voiceInput,
            circleSize: circleSize,
            finishBackground: finish.background,
            finishForeground: finish.foreground
        )
    }

    private var voiceControlButton: some View {
        ComposerVoiceControlButton(
            isDisabled: isVoiceInputDisabled,
            color: metaControlColor,
            isRecordingVoiceNote: voiceNoteRecorder.isRecording,
            supportsVoiceNotes: showsSessionControls,
            onTap: toggleVoiceInput,
            onRecordingStart: { startVoiceNoteRecording() },
            onRecordingDragChanged: { height in
                guard voiceNoteIsHeld else { return }
                voiceNoteCancelArmed = ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: height)
            },
            onRecordingEnd: { height in
                guard voiceNoteIsHeld else { return }
                finishVoiceNote(translationHeight: height)
            }
        )
    }

    private var actionButton: some View {
        Button(action: actionButtonPressed) {
            actionButtonLabel
                .frame(width: circleSize, height: circleSize)
                .background(actionButtonBackground)
                .foregroundStyle(actionButtonForeground)
                .clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .simultaneousGesture(sendHoldGesture)
        .disabled(isActionButtonDisabled)
        .accessibilityLabel(sendButton.accessibilityLabel)
        .accessibilityValue(blockedSendReason ?? "")
        .accessibilityActions {
            ForEach(sendChoices, id: \.self) { behavior in
                Button(behavior.title) { pickSendBehavior(behavior) }
            }
        }
    }

    @ViewBuilder
    private var actionButtonLabel: some View {
        if isSending || isCancellingStream || isCompressingSession {
            ProgressView()
                .tint(actionButtonForeground)
                .scaleEffect(0.9)
        } else {
            Image(systemName: sendButton.systemName)
                .font(.system(size: actionIconSize, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    private var sendHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressingSend) { _, isPressing, _ in
                isPressing = true
            }
    }

    private func scheduleSendChoices() {
        sendHold.pressBegan()
        cancelScheduledSendChoices()
        guard !sendChoices.isEmpty else { return }
        let item = DispatchWorkItem {
            sendHold.openedChoices()
            choosingSendBehavior = true
        }
        sendHoldWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledSendChoices() {
        sendHoldWorkItem?.cancel()
        sendHoldWorkItem = nil
    }

    private func closeSendChoices() {
        choosingSendBehavior = false
        sendHold.choicesClosed(isPressing: isPressingSend)
    }

    private func pickSendBehavior(_ behavior: StreamingSendBehavior) {
        closeSendChoices()
        guard sendChoices.contains(behavior) else { return }
        if voiceInput.isListening {
            voiceInput.stopBeforeSubmittingDraft()
        }
        onSend(behavior)
    }

    private var draftMayReferenceSkill: Bool {
        ComposerChipTokenizer.mayContainReference(draftMessage)
    }

    private func loadSkillSuggestionsForChipsIfNeeded() async {
        guard draftMayReferenceSkill, skillSuggestions.isEmpty else { return }
        await onLoadSkillSuggestions()
    }

    private func loadSlashAutocompleteSubArgsIfNeeded() async {
        guard showsSlashAutocomplete else {
            return
        }

        guard parsedSlashQuery.isSubArgMode,
              let command = parsedSlashQuery.command
        else {
            await onLoadSkillSuggestions()
            return
        }

        switch command.subArgs {
        case .workspaces:
            await onLoadWorkspaceSuggestions(parsedSlashQuery.argQuery)
        case .personalities:
            await onLoadPersonalitySuggestions()
        case .skills:
            await onLoadSkillSuggestions()
        case .models, .reasoningLevels, .goalActions, .none:
            break
        }
    }

    private func plusButton(usesGlass: Bool) -> some View {
        Button {
            showMediaPicker = true
        } label: {
            let icon = Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .medium))
                .foregroundStyle(metaControlColor)
                .frame(width: circleSize, height: circleSize)
            if usesGlass {
                icon
                    .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: Circle())
                    .clipShape(Circle())
            } else {
                icon.contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .tint(metaControlColor)
        .disabled(!controlGate.allowsAttaching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composer options")
    }

    @ViewBuilder
    private var gitBranchPicker: some View {
        if showsGitControls, gitViewModel.hasRepository, gitViewModel.supportsBranches {
            GitBranchPickerButton(
                currentBranch: gitViewModel.currentBranchName,
                branches: gitViewModel.branches,
                isLoading: gitViewModel.isLoadingBranches,
                isSwitching: gitViewModel.isSwitchingBranch,
                isDisabled: holdsHostControls || isWaitingForStream || gitViewModel.isWriteLocked,
                allowsCreate: gitViewModel.supportsSync,
                onSelect: { if !holdsHostControls { onSelectGitBranch($0) } },
                onCreate: { if !holdsHostControls { onCreateGitBranch($0) } },
                onRefresh: onRefreshGitBranches,
                showsPicker: $showsGitBranchPicker
            )
        }
    }

    private var metaControlFont: Font {
        AppFont.subheadline()
    }

    private var metaChevronFont: Font {
        AppFont.caption2()
    }

    private var workspaceSelector: some View {
        ComposerWorkspaceSelectorButton(
            title: workspaceTitle,
            isDisabled: isConfigurationControlDisabled,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont
        ) {
            prepareForComposerPresentation()
            showsWorkspaceSheet = true
        }
    }

    private func profileSelector(onSelect: @escaping (ProfileSummary) -> Void) -> some View {
        ComposerProfileSelectorMenu(
            profileOptions: profileOptions,
            selectedProfileName: selectedProfileName,
            selectedProfileTitle: selectedProfileTitle,
            isStatic: isSingleProfileMode,
            isDisabled: isConfigurationControlDisabled,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectProfile: onSelect
        )
    }

    private func modelEffortControl(showsTitle: Bool) -> some View {
        ComposerModelLabelButton(
            showsTitle: showsTitle,
            selection: currentModelEffortSelection,
            isDisabled: !controlGate.allowsModelSettings(approvals: approvals),
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont
        ) {
            isModelSettingsPresented.wrappedValue = true
        }
    }

    private var modelSettingsSheet: some View {
        ModelSettingsSheet(
            selection: currentModelEffortSelection,
            providerName: modelGroups.first { $0.allModels.contains(selectedModelOption) }?.name,
            favorites: ModelFavoritesStore.visibleFavoriteOptions(in: modelGroups, favoriteKeys: favoriteModelKeys),
            recents: ModelRecentsStore.visibleRecentOptions(
                in: modelGroups, recentKeys: recentModelKeys, favoriteKeys: favoriteModelKeys
            ),
            isDisabled: !controlGate.allowsConfigurationIgnoringUpdates,
            isUpdating: isUpdatingConfiguration,
            errorMessage: configurationErrorMessage,
            notice: configurationNotice,
            fastMode: fastMode,
            mayChangeFastMode: mayChangeFastMode,
            approvals: approvals,
            onSelectModel: selectModel,
            onSelectEffort: onSelectReasoningEffort,
            onSelectFastMode: onSelectFastMode,
            onSetYolo: onSetYolo,
            onSelectApprovalMode: onSelectApprovalMode,
            allModelsPicker: allModelsPicker
        )
        .modifier(HermesModelConfirmationModifier(controls: modelConfirmationControls))
    }

    private func allModelsPicker(onSelect: @escaping (ModelCatalogOption) -> Void) -> some View {
        ModelPickerSheet(
            configuration: .composer,
            modelGroups: modelGroups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID,
            favoriteModelKeys: favoriteModelKeys,
            recentModelKeys: recentModelKeys,
            isSelected: { option in
                option.matchesSelection(
                    modelID: selectedModelID,
                    providerID: selectedModelProviderID
                )
            },
            isSelectionDisabled: isConfigurationControlDisabled,
            onSelect: onSelect,
            onToggleFavorite: { option in
                favoriteModelKeys = ModelFavoritesStore(server: server).toggleFavorite(for: option)
            },
            onDeleteSavedCustom: { option in
                favoriteModelKeys = ModelFavoritesStore(server: server).removeFavorite(for: option)
                recentModelKeys = ModelRecentsStore(server: server).removeRecent(for: option)
            }
        )
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await onModelPickerOpen()
        }
    }

    private var currentModelEffortSelection: ComposerModelEffortSelection {
        ComposerModelEffortSelection(
            model: selectedModelOption,
            effort: selectedReasoningEffort,
            supportedEfforts: supportedReasoningEfforts,
            supportsEffort: showsReasoningControl ? supportsReasoningEffort : false,
            sentEffort: sentReasoningEffort
        )
    }

    private var selectedModelOption: ModelCatalogOption {
        let allModels = modelGroups.flatMap(\.allModels)
        if let selectedModelID,
           let match = allModels.firstMatchingSelection(
               modelID: selectedModelID,
               providerID: selectedModelProviderID
           ) {
            return match
        }

        let fallbackID = selectedModelID ?? selectedModelTitle
        return ModelCatalogOption(
            id: fallbackID,
            displayName: fallbackID.isEmpty ? selectedModelTitle : fallbackID,
            providerID: selectedModelProviderID
        )
    }

    private func selectModel(_ option: ModelCatalogOption) {
        recentModelKeys = ModelRecentsStore(server: server).recordRecent(option)
        onSelectModel(option)
    }

    private var composerStatus: (text: String, isError: Bool, onRetry: (() -> Void)?, fixPrompt: String?,
                                 onCancel: (() -> Void)?, onFix: (() -> Void)?, onDismiss: (() -> Void)?)? {
        if let readOnlyMessage = access.readOnlyMessage {
            return (readOnlyMessage, false, nil, nil, nil, nil, nil)
        } else if let errorMessage, let onFixError {
            return (errorMessage, true, nil, nil, nil, onFixError, nil)
        } else if access.isOffline {
            return (ChatComposerSendBlock.offline.accessibilityValue, false, nil, nil, nil, nil, nil)
        } else if isWaitingForStream && isCancellingStream {
            return (String(localized: "Stopping response..."), false, nil, nil, nil, nil, nil)
        } else if isCompressingSession {
            return (String(localized: "Compressing context..."), false, nil, nil, nil, nil, nil)
        } else if let uploadAttachmentErrorMessage {
            return (uploadAttachmentErrorMessage, true, nil, nil, nil, nil, onDismissUploadAttachmentError)
        } else if isSendingVoiceNote {
            return (String(localized: "Sending voice note..."), false, nil, nil, nil, nil, nil)
        } else if isUploadingAttachment {
            return (String(localized: "Uploading attachment..."), false, nil, nil, onCancelAttachmentUpload, nil, nil)
        } else if let steerFailure {
            return (steerFailure.message, true, steerFailure.onRetry, nil, nil, nil, nil)
        } else if let errorMessage {
            return (errorMessage, true, nil, errorFixPrompt, nil, nil, onDismissError)
        } else if let configurationErrorMessage {
            return (configurationErrorMessage, true, nil, nil, nil, nil, onDismissError)
        } else if let configurationNotice {
            return (configurationNotice, false, nil, nil, nil, nil, nil)
        } else if isUpdatingConfiguration, !isModelSettingsPresented.wrappedValue {
            return (String(localized: "Updating composer settings..."), false, nil, nil, nil, nil, nil)
        }

        return nil
    }

    private var voiceStatus: ComposerVoiceStatus? {
        guard !isDictating, let errorMessage = voiceInput.errorMessage else { return nil }
        return ComposerVoiceStatus(
            text: errorMessage,
            systemImage: "exclamationmark.triangle",
            isError: true
        )
    }

    private var voiceNoteStatus: ComposerVoiceStatus? {
        if voiceNoteRecorder.isRequestingPermission {
            return ComposerVoiceStatus(
                text: String(localized: "Requesting microphone access..."),
                systemImage: "mic.badge.plus",
                isError: false
            )
        }

        if let errorMessage = voiceNoteRecorder.errorMessage {
            return ComposerVoiceStatus(
                text: errorMessage,
                systemImage: "exclamationmark.triangle",
                isError: true
            )
        }

        return nil
    }

    private var metaControlColor: Color {
        Color(.appTextSecondary)
    }

    private var workspaceTitle: String {
        guard let selectedWorkspacePath = displayedWorkspacePath,
              !selectedWorkspacePath.isEmpty
        else {
            return String(localized: "Workspace")
        }

        if let root = workspaceRoots.first(where: { $0.path == selectedWorkspacePath }),
           let name = root.name,
           !name.isEmpty {
            return name
        }

        return selectedWorkspacePath.lastPathComponentFallback
    }

    private var displayedWorkspacePath: String? {
        optimisticWorkspacePath ?? selectedWorkspacePath
    }

    private var controlGate: ChatComposerControlGate {
        ChatComposerControlGate(
            access: access, isSending: isSending, isCompressingSession: isCompressingSession,
            isWaitingForStream: isWaitingForStream, isUpdatingConfiguration: isUpdatingConfiguration
        )
    }

    private var isConfigurationControlDisabled: Bool {
        !controlGate.allowsConfiguration
    }

    private var isVoiceInputDisabled: Bool {
        if voiceInput.isListening {
            return false
        }

        return holdsHostControls
            || isSending
            || isCompressingSession
            || isWaitingForStream
            || isUploadingAttachment
            || isUpdatingConfiguration
            || voiceInput.isRequestingPermission
    }

    private var isVoiceNoteRecordingDisabled: Bool {
        !showsSessionControls
            || holdsHostControls
            || isSending
            || isSendingVoiceNote
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

    private func actionAppearance(isStop: Bool, isDisabled: Bool) -> ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: isStop, isDisabled: isDisabled,
            colorScheme: colorScheme, tintsPrimaryActions: tintsPrimaryActions,
            tint: PrimaryActionTintSettings.colors(accentHex: accentHex, serverHex: headerLogoColorHex)
        )
    }

    private var actionButtonBackground: Color {
        actionAppearance(isStop: showsStopButton, isDisabled: isActionButtonDisabled).background
    }
    private var actionButtonForeground: Color {
        actionAppearance(isStop: showsStopButton, isDisabled: isActionButtonDisabled).foreground
    }

    private var trimmedDraftMessage: String {
        draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sendButton: ChatComposerSendButton {
        ChatComposerSendButton(
            isWaitingForStream: isWaitingForStream,
            hasText: !trimmedDraftMessage.isEmpty,
            hasQuotes: !quotes.isEmpty,
            defaultBehavior: streamingSendBehavior,
            stagedFilesDropSteer: uploadsAttachmentsOnSend && !pendingAttachments.isEmpty
        )
    }

    private var showsStopButton: Bool {
        sendButton.showsStop
    }

    private var sendChoices: [StreamingSendBehavior] {
        isActionButtonDisabled ? [] : sendButton.choices
    }

    private var isActionButtonDisabled: Bool {
        if isReadOnly {
            return true
        }

        if showsStopButton {
            return isCancellingStream
        }

        return ChatComposerSendGate.isDisabled(
            hasText: !trimmedDraftMessage.isEmpty,
            hasQuotes: !quotes.isEmpty,
            hasStagedAttachments: !pendingAttachments.isEmpty,
            block: sendBlock
        )
    }

    private var sendBlock: ChatComposerSendBlock? {
        ChatComposerSendBlock(
            isWaitingForConnection: access.hasWaitingSend,
            isOffline: access.holdsSendOffline(
                isPlainText: quotes.isEmpty && pendingAttachments.isEmpty && !trimmedDraftMessage.hasPrefix("/")
            ),
            isSending: isSending,
            isCompressingSession: isCompressingSession,
            isUploadingAttachment: isUploadingAttachment,
            isUpdatingConfiguration: isUpdatingConfiguration
        )
    }

    private var blockedSendReason: String? {
        guard !isReadOnly, !showsStopButton,
              !trimmedDraftMessage.isEmpty || !quotes.isEmpty || !pendingAttachments.isEmpty else { return nil }
        return sendBlock?.accessibilityValue
    }

    private func actionButtonPressed() {
        guard sendHold.activate() else { return }
        actionButtonTapped()
    }

    private func actionButtonTapped() {
        guard !isActionButtonDisabled else { return }
        if showsStopButton {
            onCancel()
        } else {
            if voiceInput.isListening {
                voiceInput.stopBeforeSubmittingDraft()
            }
            onSend(sendButton.runningBehavior)
        }
    }

    private var keyboardCommands: ComposerKeyboardCommands {
        let button = sendButton
        var commands = ComposerKeyboardCommands()
        if !button.showsStop, !isActionButtonDisabled {
            commands.send = .init(title: button.accessibilityLabel) {
                guard !showsStopButton else { return }
                actionButtonTapped()
            }
        }
        if let alternate = isActionButtonDisabled ? nil : button.alternateBehavior {
            commands.alternateSend = .init(title: alternate.settingsDescription) { pickSendBehavior(alternate) }
        }
        if choosingSendBehavior {
            commands.escape = .init(title: String(localized: "Close"), perform: closeSendChoices)
        } else if showsSlashAutocomplete || showsFileAutocomplete {
            commands.escape = .init(title: String(localized: "Close")) {
                dismissedSuggestionsAnchor = SuggestionAnchor(draft: draftMessage, caret: composerSelection.range)
            }
        } else if isWaitingForStream, !isReadOnly, !isCancellingStream {
            commands.escape = .init(title: String(localized: "Stop response"), perform: onCancel)
        }
        return commands
    }

    @MainActor
    private func autoStartVoiceInputIfNeeded() {
        guard autoStartsVoiceInput, !didAutoStartVoiceInput else { return }
        guard scenePhase == .active, !AppLock.shared.isLocked else { return }
        didAutoStartVoiceInput = true
        guard !voiceInput.isListening, !isVoiceInputDisabled else { return }
        toggleVoiceInput()
    }

    @MainActor
    private func toggleVoiceInput() {
        guard !voiceNoteRecorder.isRecording else { return }
        voiceInput.transcribe = hermesTranscriber ?? apiClient?.dictationTranscriber
        voiceInput.providerPreference = ComposerSTTProviderPreference.storedValue(sttProviderPreferenceRawValue)
        restoresFocusAfterDictation = isFocused
        if isFocused {
            UIApplication.shared.sendAction(#selector(ComposerChipTextView.resignForDictation), to: nil, from: nil, for: nil)
            isFocused = false
        }
        let start = voiceInput.scheduleToggle(
            draftState: { ComposerVoiceDraftState(text: draftMessage, selection: composerSelection) },
            updateDraft: { update in
                editDraft(update.text)
                composerSelection = composerSelection.moved(to: update.caret)
            }
        )
        Task {
            await start.value
            if !isDictating { restoreFocusAfterDictation() }
        }
    }

    private func restoreFocusAfterDictation() {
        guard restoresFocusAfterDictation else { return }
        restoresFocusAfterDictation = false
        isCardOpen = true
        isFocused = true
    }

    @MainActor
    private func startVoiceNoteRecording(isHeld: Bool = true) {
        guard !isVoiceNoteRecordingDisabled, !voiceNoteRecorder.isRecording else { return }
        voiceNoteIsHeld = isHeld

        if voiceInput.isListening {
            voiceInput.stopKeepingTranscript()
        }
        voiceNoteCancelArmed = false
        Task { await voiceNoteRecorder.begin() }
    }

    @MainActor
    private func finishVoiceNote(translationHeight: CGFloat) {
        let shouldCancel = ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: translationHeight)
        voiceNoteCancelArmed = false

        guard !shouldCancel else {
            voiceNoteRecorder.cancel()
            return
        }

        guard let note = voiceNoteRecorder.finish() else { return }
        onSendVoiceNote(note.data, note.filename)
    }

    @MainActor
    private func cancelVoiceNote() {
        voiceNoteCancelArmed = false
        voiceNoteRecorder.cancel()
    }

    private var canFocusTextView: Bool {
        !isReadOnly && !isUploadingAttachment && uploadAttachmentErrorMessage == nil
    }

    private func prepareForComposerPresentation() {
        shouldRestoreFocusAfterPresentation = isFocused
        if isFocused {
            isFocused = false
        }
    }

    private func presentQuote(_ quote: ComposerQuote) {
        prepareForComposerPresentation()
        selectedQuote = quote
    }

    private func removeQuote(_ id: UUID) {
        quotes.removeAll { $0.id == id }
    }

    private func restoreFocusAfterPresentationIfNeeded() {
        guard shouldRestoreFocusAfterPresentation else { return }
        shouldRestoreFocusAfterPresentation = false
        requestTextViewFocusIfPossible()
    }

    private func restoreFocusAfterPresentationDismissalSettles() {
        guard shouldRestoreFocusAfterPresentation else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard shouldRestoreFocusAfterPresentation else { return }
            restoreFocusAfterPresentationIfNeeded()
        }
    }

    private func deferFocusRestoreUntilUploadCompletes() {
        guard shouldRestoreFocusAfterPresentation else { return }
        shouldRestoreFocusAfterPresentation = false
        deferredUploadFocusPhase = .waitingForUploadStart(afterGeneration: attachmentUploadGeneration)
    }

    private func handleDeferredUploadStart(_ newGeneration: Int) {
        guard case let .waitingForUploadStart(afterGeneration) = deferredUploadFocusPhase,
              newGeneration > afterGeneration
        else { return }

        if attachmentUploadCount == 0 {
            restoreFocusAfterDeferredUploadIfNeeded()
        } else {
            deferredUploadFocusPhase = .waitingForUploadsToFinish
        }
    }

    private func handleDeferredUploadCountChange(_ newCount: Int) {
        guard case .waitingForUploadsToFinish = deferredUploadFocusPhase else { return }
        if newCount == 0 {
            restoreFocusAfterDeferredUploadIfNeeded()
        }
    }

    private func restoreFocusAfterDeferredUploadIfNeeded() {
        guard deferredUploadFocusPhase != .none else { return }
        deferredUploadFocusPhase = .none
        requestTextViewFocusIfPossible()
    }

    private func requestTextViewFocusIfPossible() {
        guard canFocusTextView else { return }
        isCardOpen = true

        Task { @MainActor in
            await Task.yield()
            guard canFocusTextView else {
                isCardOpen = isFocused
                return
            }
            isFocused = true
        }
    }

    private func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.userCancelled.rawValue
    }
}
