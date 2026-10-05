import SwiftUI
import UIKit

/// A composer status line that offers Retry, such as "Couldn't steer".
struct ComposerRetryableStatus {
    let message: String
    let onRetry: () -> Void
}

private struct ComposerStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let text: String
    let isError: Bool
    let isDismissible: Bool
    let onRetry: (() -> Void)?
    /// Offers Copy fix prompt, which puts this text on the pasteboard (#955).
    let fixPrompt: String?
    /// Offers Cancel, which stops a Hermes send's uploads (#1012).
    let onCancel: (() -> Void)?
    let onDismiss: () -> Void
    @State private var didCopyFixPrompt = false

    var body: some View {
        // At accessibility sizes Copy fix prompt drops below the message,
        // like the transcript log rows' stacked labels.
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

            if let fixPrompt {
                fixPromptButton(fixPrompt)
            }

            if isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(textColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss attachment error")
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

    /// Swaps to "Copied" without animation and announces it for VoiceOver.
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
        // Wraps like Retry would: a long translation shares the row with the
        // message instead of squeezing it, and never overflows when stacked.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(didCopyFixPrompt ? Text("Fix prompt copied") : Text("Copy fix prompt"))
        .accessibilityHint(Text("Copies a prompt that asks your Hermes agent to restart Hermes WebUI."))
    }

    private var textColor: Color {
        isError ? Color(.label) : Color.secondary
    }

    private var backgroundColor: Color {
        isError ? Color.red.opacity(0.08) : Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        isError ? Color.red.opacity(0.25) : Color(.separator).opacity(0.25)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var plusIconSize: CGFloat = 20

    /// t3code sizing: every circle in the composer is 44 pt, which is also the
    /// minimum hit target, so no invisible hit padding is needed.
    private let circleSize = ChatComposerMetrics.actionSize
    private let pillInset = ChatComposerMetrics.pillInset

    /// The draft. Pass the owner's plain `$state`, not a get/set binding:
    /// SwiftUI re-runs the owner of a get/set binding on every keystroke. The
    /// owner hears about edits through `onDraftEdit` instead.
    @Binding var draftMessage: String
    @Binding var quotes: [ComposerQuote]
    @Binding var isFocused: Bool
    let isSending: Bool
    let isCompressingSession: Bool
    let isWaitingForStream: Bool
    let isCancellingStream: Bool
    let readOnlyMessage: String?
    let errorMessage: String?
    /// Offered as Copy fix prompt on the `errorMessage` banner (#955).
    let errorFixPrompt: String?
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
    /// Server base URL for the workspace-registry manager; nil hides the
    /// Manage affordance in the workspace picker.
    let workspaceManagementServer: URL?
    let personalitySuggestions: [String]
    let skillSuggestions: [SkillSlashSuggestion]
    /// Whether a skills request has succeeded, even an empty one. Lets the
    /// mid-sentence close rule tell "still loading" from "loaded, none match".
    let hasLoadedSkillSuggestions: Bool
    let agentCommands: [AgentCommand]
    let profileOptions: [ProfileSummary]
    let isSingleProfileMode: Bool
    let selectedProfileName: String?
    let selectedProfileTitle: String
    let selectedReasoningEffort: String?
    /// Model-aware effort vocabulary; `nil` → full static list (issue #18).
    let supportedReasoningEfforts: [String]?
    let supportsReasoningEffort: Bool?
    /// When false the model has no effort setting, so the combined title omits it.
    let showsReasoningControl: Bool
    let isUpdatingConfiguration: Bool
    let pendingAttachments: [PendingAttachment]
    let isUploadingAttachment: Bool
    let attachmentUploadCount: Int
    let attachmentUploadGeneration: Int
    let isSendingVoiceNote: Bool
    /// When true, dictation auto-starts once this composer appears with the app active —
    /// the "New Chat with Voice" App Intent (#338). Defaults to false for normal composers.
    let autoStartsVoiceInput: Bool
    let apiClient: APIClient?
    /// This chat's server-side session, which the `@` panel lists workspace
    /// files for. Nil before the session exists, which keeps the panel closed.
    let sessionID: String?
    /// The workspace files already picked in this chat. The editor draws their
    /// `@path` references as chips; the view model owns the set so the sent
    /// transcript can draw the same ones.
    let chipFilePaths: Set<String>
    /// The `@` panel's rows and its directory listings. Owned by the view model
    /// so a folder listed to confirm a restored draft's references is not listed
    /// again the first time the panel opens.
    let filePathSearch: ComposerFilePathSearch
    let uploadAttachmentErrorMessage: String?
    /// "Couldn't steer" with Retry, after a steer didn't reach the run.
    let steerFailure: ComposerRetryableStatus?
    /// The Send While Responding default: what a tap on Send does mid-run, and
    /// the glyph and VoiceOver label that say so.
    let streamingSendBehavior: StreamingSendBehavior
    /// Sends with the default; a mid-run send uses `streamingSendBehavior`.
    let onSend: () -> Void
    /// Sends this one message with a behavior picked from the send-choice card
    /// or a VoiceOver action. The default does not change.
    let onSendWithBehavior: (StreamingSendBehavior) -> Void
    let onSendVoiceNote: (Data, String) -> Void
    let onCancel: () -> Void
    let onSelectModel: (ModelCatalogOption) -> Void
    let onModelPickerOpen: () async -> Void
    let onSelectReasoningEffort: (String) -> Void
    let onLoadWorkspaceSuggestions: (String) async -> Void
    let onWorkspaceRegistryChanged: () async -> Void
    let onLoadPersonalitySuggestions: () async -> Void
    let onLoadSkillSuggestions: () async -> Void
    let onSelectWorkspace: (String) async -> Void
    let onSelectProfile: (ProfileSummary) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPhotoMediaSelected: ([HermexPickedMedia]) -> Void
    let onFileURLsSelected: ([URL]) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPreviewAttachment: (PendingAttachment) -> Void
    let onDismissUploadAttachmentError: () -> Void
    /// A workspace file the user just picked, for the chip catalog.
    let onSelectFileReference: (String) -> Void
    /// The draft, each time its finished `@…` references change (and once on
    /// appear), so the owner can confirm which name workspace files. Scanned
    /// here because this view already re-runs per keystroke; the owner never
    /// has to read the draft in its own body.
    let onFileReferenceCandidatesChange: (String) async -> Void
    /// Each edit the user makes to the draft here (typing, completions,
    /// dictation), after it lands in `draftMessage`, for the owner to persist.
    let onDraftEdit: (String) -> Void
    /// The chat's last sent message, for ↑ in an empty composer on a hardware
    /// keyboard. A closure, so the transcript is scanned only when ↑ is pressed.
    var recallLastSentText: (() -> String?)? = nil
    /// A file chip the user tapped, by workspace-relative path.
    let onOpenFileReference: (String) -> Void
    let onSelectGitBranch: (GitCheckoutTarget) -> Void
    let onCreateGitBranch: (GitCheckoutTarget) -> Void
    let onRefreshGitBranches: () -> Void
    /// False on a Hermes session (#1010): the workspace selector, the branch picker, voice
    /// notes and the `/` panel stay hidden until their phases land. The + menu, dictation
    /// and the context indicator stay.
    var showsSessionControls = true
    /// A Hermes session's model and Profile chips (#1015), shown while the rest of
    /// `showsSessionControls` stays hidden.
    var showsModelAndProfileControls = false
    /// A configuration change that has not landed yet, such as a model the host applies
    /// after the running response. Shown below any configuration error.
    var configurationNotice: String?
    /// A Hermes session (#1012): staged files upload when they are sent, under Bot Chat's
    /// rules. Up to eight, and Steer drops out while a response runs.
    var uploadsAttachmentsOnSend = false
    /// Set while a send uploads its files, for the status line's Cancel.
    var onCancelAttachmentUpload: (() -> Void)?

    @State private var textFieldHeight: CGFloat = 0
    @State private var textInputHeight: CGFloat = 22
    /// Where the caret is in `draftMessage`, in UTF-16 units. Transient by
    /// design: a restored draft starts with the caret at its end, not wherever
    /// it was left last week.
    @State private var composerSelection = ComposerSelection()
    @State private var noticeMessage: String?
    @State private var showsAllModelsSheet = false
    @State private var showsWorkspaceSheet = false
    @State private var optimisticWorkspacePath: String?
    @State private var favoriteModelKeys = ModelFavoritesStore.shared.favoriteKeys
    @State private var recentModelKeys = ModelRecentsStore.shared.recentKeys
    @State private var keyboardIsVisible = false
    @State private var shouldRestoreFocusAfterPresentation = false
    @State private var selectedQuote: ComposerQuote?
    /// True while the send-choice card is up after a hold on Send mid-run.
    @State private var choosingSendBehavior = false
    /// Keeps the release of a hold that opened the card from also sending.
    @State private var sendHold = ChatComposerSendHold()
    @State private var sendHoldWorkItem: DispatchWorkItem?
    @GestureState private var isPressingSend = false

    @State private var deferredUploadFocusPhase: DeferredUploadFocusPhase = .none
    @State private var showMediaPicker = false
    @State private var presentFilesAfterMediaPickerDismisses = false
    @State private var showFileImporter = false
    @State private var voiceInput = ComposerVoiceInputController()
    @State private var voiceNoteRecorder = ComposerVoiceNoteRecorder()
    @State private var voiceNoteCancelArmed = false
    @State private var didAutoStartVoiceInput = false
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    private var isReadOnly: Bool {
        readOnlyMessage != nil
    }

    private enum DeferredUploadFocusPhase: Equatable {
        case none
        case waitingForUploadStart(afterGeneration: Int)
        case waitingForUploadsToFinish
    }

    /// The `/…` the caret is sitting in, whether that is the start of the draft
    /// or the middle of a sentence.
    private var slashTrigger: ComposerSlashTrigger? {
        ComposerSlashTrigger.detect(in: draftMessage, selection: composerSelection.range)
    }

    /// The `@…` the caret is sitting in, or `nil` when there is none.
    ///
    /// Needs a session to list, since every path the panel offers comes from
    /// that session's workspace.
    private var fileTrigger: ComposerFileTrigger? {
        guard !isReadOnly, apiClient != nil, fileReferenceSessionID != nil else { return nil }
        return ComposerFileTrigger.detect(in: draftMessage, selection: composerSelection.range)
    }

    private var showsFileAutocomplete: Bool {
        fileTrigger != nil
    }

    private var fileReferenceSessionID: String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    /// What the panel filters on, or `nil` when it should be closed.
    ///
    /// The `@` panel wins when both triggers match: a `/` inside a path never
    /// triggers at all (it follows a non-space), but an `@` inside a command's
    /// free-form argument is still a file reference.
    ///
    /// A command the user has typed past no longer produces a trigger at all —
    /// `ComposerSlashTrigger` ends at the space after a command that takes no
    /// sub-argument — so besides the trigger itself, three things close the
    /// panel: a settled `/skills` invocation, a settled goal action, and a
    /// mid-sentence word no loaded skill matches.
    private var slashQuery: String? {
        guard showsSessionControls, fileTrigger == nil, let query = slashTrigger?.text else { return nil }

        let parsed = ParsedSlashQuery(query: query)
        if parsed.commandName.lowercased() == "skills",
           SlashSkillFormatter.invocation(from: parsed.argQuery, suggestions: skillSuggestions) != nil {
            return nil
        }

        if parsed.command?.subArgs == .goalActions,
           parsed.isSubArgMode,
           !parsed.argQuery.isEmpty,
           !SlashCommandCatalog.goalActions.contains(where: {
               $0.hasPrefix(parsed.argQuery.lowercased())
           }) {
            return nil
        }

        // Mid-sentence the panel's only content is skills, so once the catalog
        // question is settled — a request has succeeded, even one that found
        // no skills — and nothing matches the typed word, close rather than
        // hold an empty box up. Before that, keep the panel open so its load
        // task can fetch the list and judge the word against real data.
        if slashTrigger?.startsDraft == false,
           hasLoadedSkillSuggestions,
           SlashSkillFormatter.matching(parsed.commandName, in: skillSuggestions).isEmpty {
            return nil
        }

        return query
    }

    private var showsSlashAutocomplete: Bool {
        slashQuery != nil
    }

    /// Whether the panel may only offer skills. The send path runs a command
    /// only when the trimmed draft starts with `/`, so past other text a
    /// command row would be inserted text nothing executes.
    private var showsSlashAutocompleteSkillsOnly: Bool {
        !(slashTrigger?.startsDraft ?? true)
    }

    /// Every write the user makes to the draft goes through here, so the owner
    /// can persist it.
    private func editDraft(_ text: String) {
        draftMessage = text
        onDraftEdit(text)
    }

    /// Swaps the `/…` at the caret for `replacement` and leaves the caret just
    /// after it, so the rest of the draft survives accepting a row.
    private func applyCompletion(_ replacement: String) {
        guard let trigger = slashTrigger else { return }

        let completed = trigger.applying(replacement, to: draftMessage)
        editDraft(completed.draft)
        composerSelection = composerSelection.moved(to: completed.selection)
    }

    /// A row the user tapped in the `/` panel: completes it with a selection
    /// tick. Dismissing the panel calls `applyCompletion` directly, silently.
    private func pickCompletion(_ replacement: String) {
        applyCompletion(replacement)
        ChatHaptics.autocompleteAccepted(isEnabled: isHapticsEnabled)
    }

    /// Swaps the `@…` at the caret for the picked entry.
    ///
    /// A file finishes the reference: `@path` plus a space, recorded so the
    /// editor draws it as a chip. A folder is a step on the way, so it inserts
    /// with a trailing `/` and no space and the panel stays open listing what is
    /// inside it. Only files are recorded, which is what keeps a folder
    /// reference from becoming a chip that opens nothing. Either pick plays a
    /// selection tick, so a folder tap that keeps the panel open still lands.
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
        ParsedSlashQuery(query: slashQuery ?? "")
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
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 6) {
                if voiceNoteRecorder.isRecording {
                    ComposerVoiceRecordingBar(
                        elapsed: voiceNoteRecorder.elapsed,
                        isCancelArmed: voiceNoteCancelArmed,
                        onStop: { finishVoiceNote(translationHeight: 0) },
                        onCancel: cancelVoiceNote
                    )
                    .padding(.horizontal, 16)
                } else if let voiceNoteStatus {
                    ComposerVoiceStatusView(status: voiceNoteStatus)
                } else if let voiceStatus {
                    ComposerVoiceStatusView(status: voiceStatus)
                } else if let composerStatus {
                    ComposerStatusView(
                        text: composerStatus.text,
                        isError: composerStatus.isError,
                        isDismissible: composerStatus.isDismissible,
                        onRetry: composerStatus.onRetry,
                        fixPrompt: composerStatus.fixPrompt,
                        onCancel: composerStatus.onCancel,
                        onDismiss: onDismissUploadAttachmentError
                    )
                }

                Group {
                    if let fileTrigger, let sessionID = fileReferenceSessionID, let apiClient {
                        FilePathAutocompleteView(
                            query: fileTrigger.query,
                            search: filePathSearch,
                            load: { query in
                                await filePathSearch.search(query, sessionID: sessionID, apiClient: apiClient)
                            },
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
                            onDismiss: {
                                applyCompletion("")
                            }
                        )
                        .padding(.horizontal)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsSlashAutocomplete)
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsFileAutocomplete)

                composerSurface
                    .padding(.horizontal)

                if isExpanded {
                    toolbarRow
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
                        // Solid chat background behind the controls: the card
                        // above is glass on purpose, but transcript text
                        // scrolling under the row made the pills unreadable.
                        // Bleeds up into the gap under the card and down past
                        // the keyboard gap and the bottom safe area, so no strip
                        // of transcript shows around the row.
                        .background(
                            Color(.systemBackground)
                                .padding(.top, -10)
                                .padding(.bottom, -12)
                                .ignoresSafeArea(edges: .bottom)
                        )
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            // Focus flips arrive from UIKit outside any withAnimation, so the
            // morph and the row's insertion take their animation from here.
            .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: isExpanded)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onHeightChange(proxy.size.height)
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        onHeightChange(newHeight)
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
        // The same keyboard-retaining overlay as the "+" picker and the Bot
        // composer's send-choice card, so the keyboard stays up.
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
        // The run ending, or Send turning into Stop, closes the card and drops
        // a hold that has not opened it yet, as the Bot composer does.
        .onChange(of: sendChoices) { _, choices in
            guard choices.isEmpty else { return }
            cancelScheduledSendChoices()
            closeSendChoices()
        }
        .onChange(of: isPressingSend) { _, isPressing in
            if isPressing {
                scheduleSendChoices()
            } else {
                cancelScheduledSendChoices()
            }
        }
        .task(id: draftMayReferenceSkill) {
            await loadSkillSuggestionsForChipsIfNeeded()
        }
        .task(id: ComposerChipTokenizer.fileReferenceCandidates(in: draftMessage)) {
            await onFileReferenceCandidatesChange(draftMessage)
        }
        .task(id: slashAutocompleteLoadKey) {
            await loadSlashAutocompleteSubArgsIfNeeded()
        }
        .task(id: AppLock.shared.isLocked) {
            // Cold path: the composer appears already active (the usual case for the
            // "New Chat with Voice" intent once its session is created) — start here.
            // Runs again when the app lock changes, since dictation waits for it (#885);
            // one modifier keeps this chain inside CI Xcode's type-checking budget.
            if AppLock.shared.isLocked { voiceInput.suspend() }
            else if scenePhase == .active { voiceInput.resume() }
            autoStartVoiceInputIfNeeded()
        }
        .onChange(of: sessionID) { _, _ in voiceInput.stopBeforeSubmittingDraft() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                voiceInput.suspend()
                // Backgrounding stops the recorder's run-loop ticker, so cancel
                // the in-flight recording rather than leave it silently stalled.
                cancelVoiceNote()
            } else {
                voiceInput.resume()
                // An intent that opened this composer may have foregrounded the app
                // a beat after it appeared; auto-start once we're active (#338).
                autoStartVoiceInputIfNeeded()
            }
        }
        .onChange(of: voiceNoteRecorder.elapsed) { _, elapsed in
            // Enforce the max-duration cap: auto-stop and send (not cancel) once
            // the clip hits the limit, mirroring a finger release.
            if voiceNoteRecorder.isRecording, elapsed >= ComposerVoiceNoteRecorder.maximumDuration {
                finishVoiceNote(translationHeight: 0)
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
        .sheet(isPresented: $showsAllModelsSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
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
                onSelect: { option in
                    selectModel(option)
                },
                onToggleFavorite: { option in
                    favoriteModelKeys = ModelFavoritesStore.shared.toggleFavorite(for: option)
                },
                onDeleteSavedCustom: { option in
                    favoriteModelKeys = ModelFavoritesStore.shared.removeFavorite(for: option)
                    recentModelKeys = ModelRecentsStore.shared.removeRecent(for: option)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .task {
                await onModelPickerOpen()
            }
        }
        .sheet(isPresented: $showsWorkspaceSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            ComposerWorkspacePickerSheet(
                workspaceRoots: workspaceRoots,
                selectedWorkspacePath: displayedWorkspacePath,
                suggestions: workspaceSuggestions,
                managementServer: isReadOnly ? nil : workspaceManagementServer,
                onLoadSuggestions: onLoadWorkspaceSuggestions,
                onSelect: { path in
                    optimisticWorkspacePath = path
                    showsWorkspaceSheet = false
                    await onSelectWorkspace(path)
                },
                onRegistryChanged: onWorkspaceRegistryChanged
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedQuote, onDismiss: restoreFocusAfterPresentationIfNeeded) { quote in
            ComposerQuoteDetailView(
                quote: quote,
                onRemove: {
                    removeQuote(quote.id)
                    selectedQuote = nil
                }
            )
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
        .onDisappear {
            voiceInput.stopBeforeSubmittingDraft()
            cancelVoiceNote()
            cancelScheduledSendChoices()
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
    }

    /// Pill while the editor is idle; card while it is focused or a composer
    /// sheet is up (so a picker never snaps it shut). `shouldRestoreFocus…`
    /// bridges the gap between a sheet dismissing and focus coming back.
    private var isExpanded: Bool {
        isFocused
            || !quotes.isEmpty
            || shouldRestoreFocusAfterPresentation
            || showsAllModelsSheet
            || showsWorkspaceSheet
            || showMediaPicker
            || showFileImporter
    }

    /// The glass surface: one text view in both states so focus and the draft
    /// survive the morph. Pill: text, thumbnails, mic, Stop/Send in a row.
    /// Card: strip above the editor, controls move to `toolbarRow` below.
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
                ComposerTextInputView(
                    text: Binding(get: { draftMessage }, set: editDraft),
                    selection: $composerSelection,
                    isFocused: $isFocused,
                    inputHeight: $textInputHeight,
                    measuredHeight: $textFieldHeight,
                    isDisabled: isReadOnly,
                    isCollapsed: !isExpanded,
                    isKeyboardSendEnabled: !showsStopButton && !isActionButtonDisabled,
                    verticalPadding: 12,
                    chipSkills: skillSuggestions,
                    chipFilePaths: chipFilePaths,
                    quotes: quotes,
                    onKeyboardSend: actionButtonTapped,
                    onPasteFileProviders: onPasteFileProviders,
                    onPasteFileURLs: onPasteFileURLs,
                    onPasteImageProviders: onPasteImageProviders,
                    onPasteImages: onPasteImages,
                    onTapChip: { token in
                        // A skill chip is inert; a file chip opens the file.
                        guard let path = token.filePath else { return }
                        onOpenFileReference(path)
                    },
                    onTapQuote: presentQuote,
                    onRemoveQuote: removeQuote,
                    recallLastSentText: recallLastSentText
                )

                if !isExpanded {
                    ComposerAttachmentPillPreview(
                        attachments: pendingAttachments,
                        onPreview: onPreviewAttachment
                    )

                    voiceControlButton

                    actionButton
                }
            }
            .padding(.trailing, isExpanded ? 0 : pillInset)
            .padding(.vertical, isExpanded ? 0 : pillInset)
        }
        .padding(.top, isExpanded ? 2 : 0)
        .padding(.bottom, isExpanded ? 4 : 0)
        .modifier(ChatComposerSurfaceStyle(isExpanded: isExpanded))
    }

    /// Card-state row under the surface: a scroller of secondary controls plus
    /// the pinned Stop/Send circle. Visual order is VoiceOver order.
    private var toolbarRow: some View {
        HStack(alignment: .center, spacing: 8) {
            ComposerToolbarScroller {
                composerPlusMenu

                if showsSessionControls || showsModelAndProfileControls {
                    modelEffortControl

                    if showsSessionControls { workspaceSelector }

                    profileSelector

                    if showsSessionControls { gitBranchPicker }
                }

                voiceControlButton

                ContextWindowIndicatorView(snapshot: contextWindowSnapshot)
                    .padding(.horizontal, 4)
            }

            actionButton
        }
    }

    private var voiceControlButton: some View {
        ComposerVoiceControlButton(
            isListening: voiceInput.isListening,
            isDisabled: isVoiceInputDisabled,
            color: metaControlColor,
            isRecordingVoiceNote: voiceNoteRecorder.isRecording,
            onTap: toggleVoiceInput,
            onRecordingStart: startVoiceNoteRecording,
            onRecordingDragChanged: { height in
                voiceNoteCancelArmed = ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: height)
            },
            onRecordingEnd: { height in
                finishVoiceNote(translationHeight: height)
            }
        )
    }

    /// One trailing circle in both states. Stop while a response streams and the
    /// draft is empty; Send as soon as there is text. Mid-run a tap sends with
    /// the Send While Responding default, and a hold opens the send-choice card
    /// for this one message (`ChatComposerSendButton`).
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
        .accessibilityActions {
            // VoiceOver can't hold, so each choice is a named action.
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
            // Morphs between Stop and the default's Send glyph; instant
            // with Reduce Motion.
            Image(systemName: sendButton.systemName)
                .font(.system(size: actionIconSize, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    /// Times a hold the way the mic does (`ComposerVoiceControlButton`): one
    /// `DragGesture(minimumDistance: 0)` beside the button's own tap, where
    /// touch-down schedules the card and lifting before the delay cancels it.
    /// The gesture state resets on a cancelled touch too, so a hold can never
    /// stay armed.
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
        // The mic's hold delay, so the composer's two holds feel alike.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledSendChoices() {
        sendHoldWorkItem?.cancel()
        sendHoldWorkItem = nil
    }

    /// Closes the send-choice card. A hold still down keeps its release from
    /// sending (or stopping); see `ChatComposerSendHold`.
    private func closeSendChoices() {
        choosingSendBehavior = false
        sendHold.choicesClosed(isPressing: isPressingSend)
    }

    /// The card's rows and VoiceOver's named actions both land here.
    private func pickSendBehavior(_ behavior: StreamingSendBehavior) {
        closeSendChoices()
        // A pick can outlive the run or the draft it was offered for.
        guard sendChoices.contains(behavior) else { return }
        if voiceInput.isListening {
            voiceInput.stopBeforeSubmittingDraft()
        }
        onSendWithBehavior(behavior)
    }

    /// Whether the draft holds anything that could be drawn as a skill chip.
    private var draftMayReferenceSkill: Bool {
        ComposerChipTokenizer.mayContainReference(draftMessage)
    }

    /// A draft restored from the store can already name a skill, and chips are
    /// only drawn for skills the app has heard of. Fetching the list the moment
    /// the draft looks like it needs one keeps a reopened chat from showing raw
    /// `/skill` text, without a skills request on every chat that never uses one.
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

    private var composerPlusMenu: some View {
        Button {
            showMediaPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .medium))
                .foregroundStyle(metaControlColor)
                .frame(width: circleSize, height: circleSize)
                // Inside the masked toolbar scroller, like the context ring.
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .ultraThinMaterial,
                    inheritsClipping: true,
                    in: Circle()
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(metaControlColor)
        .disabled(isConfigurationControlDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composer options")
    }

    @ViewBuilder
    private var gitBranchPicker: some View {
        // One "Git Actions" toggle covers every git control in chat (#189), so the
        // branch chip goes with the toolbar menu rather than lingering alone.
        if showsGitControls, gitViewModel.hasRepository {
            GitBranchPickerButton(
                currentBranch: gitViewModel.currentBranchName,
                branches: gitViewModel.branches,
                isLoading: gitViewModel.isLoadingBranches,
                isSwitching: gitViewModel.isSwitchingBranch,
                isDisabled: isReadOnly || isWaitingForStream,
                onSelect: onSelectGitBranch,
                onCreate: onCreateGitBranch,
                onRefresh: onRefreshGitBranches
            )
        }
    }

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
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

    private var profileSelector: some View {
        ComposerProfileSelectorMenu(
            profileOptions: profileOptions,
            selectedProfileName: selectedProfileName,
            selectedProfileTitle: selectedProfileTitle,
            isStatic: isSingleProfileMode,
            isDisabled: isConfigurationControlDisabled,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectProfile: onSelectProfile
        )
    }

    private var modelEffortControl: some View {
        ComposerModelEffortMenu(
            selection: currentModelEffortSelection,
            modelGroups: modelGroups,
            favoriteModelKeys: favoriteModelKeys,
            recentModelKeys: recentModelKeys,
            isDisabled: isConfigurationControlDisabled,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectModel: selectModel,
            onSelectEffort: onSelectReasoningEffort,
            onShowAllModels: showAllModels
        )
    }

    private var currentModelEffortSelection: ComposerModelEffortSelection {
        ComposerModelEffortSelection(
            model: selectedModelOption,
            effort: selectedReasoningEffort,
            supportedEfforts: supportedReasoningEfforts,
            supportsEffort: showsReasoningControl ? supportsReasoningEffort : false
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

        return ModelCatalogOption(
            id: selectedModelID ?? selectedModelTitle,
            displayName: selectedModelTitle,
            providerID: selectedModelProviderID
        )
    }

    private func selectModel(_ option: ModelCatalogOption) {
        recentModelKeys = ModelRecentsStore.shared.recordRecent(option)
        onSelectModel(option)
    }

    private func showAllModels() {
        prepareForComposerPresentation()
        showsAllModelsSheet = true
    }

    private var composerStatus: (text: String, isError: Bool, isDismissible: Bool, onRetry: (() -> Void)?, fixPrompt: String?,
                                 onCancel: (() -> Void)?)? {
        if let readOnlyMessage {
            return (readOnlyMessage, false, false, nil, nil, nil)
        } else if isWaitingForStream && isCancellingStream {
            return (String(localized: "Stopping response..."), false, false, nil, nil, nil)
        } else if isCompressingSession {
            return (String(localized: "Compressing context..."), false, false, nil, nil, nil)
        } else if let uploadAttachmentErrorMessage {
            return (uploadAttachmentErrorMessage, true, true, nil, nil, nil)
        } else if isSendingVoiceNote {
            return (String(localized: "Sending voice note..."), false, false, nil, nil, nil)
        } else if isUploadingAttachment {
            return (String(localized: "Uploading attachment..."), false, false, nil, nil, onCancelAttachmentUpload)
        } else if let steerFailure {
            return (steerFailure.message, true, false, steerFailure.onRetry, nil, nil)
        } else if let errorMessage {
            return (errorMessage, true, false, nil, errorFixPrompt, nil)
        } else if let configurationErrorMessage {
            return (configurationErrorMessage, true, false, nil, nil, nil)
        } else if let configurationNotice {
            return (configurationNotice, false, false, nil, nil, nil)
        } else if isUpdatingConfiguration {
            return (String(localized: "Updating composer settings..."), false, false, nil, nil, nil)
        }

        return nil
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

        if let errorMessage = voiceInput.errorMessage {
            return ComposerVoiceStatus(
                text: errorMessage,
                systemImage: "exclamationmark.triangle",
                isError: true
            )
        }

        return nil
    }

    /// Voice-note status shown above the composer when *not* actively recording
    /// (the recording bar covers that case): the permission prompt and recorder
    /// errors like a denied microphone.
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
        Color(.secondaryLabel)
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

    private var isConfigurationControlDisabled: Bool {
        isReadOnly || isSending || isCompressingSession || isWaitingForStream || isUpdatingConfiguration
    }

    private var isVoiceInputDisabled: Bool {
        if voiceInput.isListening {
            return false
        }

        return isReadOnly
            || isSending
            || isCompressingSession
            || isWaitingForStream
            || isUploadingAttachment
            || isUpdatingConfiguration
            || voiceInput.isRequestingPermission
    }

    /// Whether a hold-to-record gesture is allowed to start a new voice note.
    /// Recording mid-stream is fine (it queues like any send), so unlike dictation
    /// this does not block on `isWaitingForStream`.
    private var isVoiceNoteRecordingDisabled: Bool {
        !showsSessionControls
            || isReadOnly
            || isSending
            || isSendingVoiceNote
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

    private var actionAppearance: ChatComposerActionAppearance {
        ChatComposerActionAppearance(
            isStop: showsStopButton, isDisabled: isActionButtonDisabled,
            colorScheme: colorScheme, tintsPrimaryActions: tintsPrimaryActions,
            themeHex: headerLogoColorHex
        )
    }

    private var actionButtonBackground: Color { actionAppearance.background }
    private var actionButtonForeground: Color { actionAppearance.foreground }

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

    /// What a hold on Send offers right now: nothing while Send is disabled.
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
            isSending: isSending,
            isCompressingSession: isCompressingSession,
            isUploadingAttachment: isUploadingAttachment,
            isUpdatingConfiguration: isUpdatingConfiguration
        )
    }

    /// A tap on the circle. The release of a hold that opened the send-choice
    /// card lands here too, and is dropped so the hold never also sends.
    private func actionButtonPressed() {
        guard sendHold.activate() else { return }
        actionButtonTapped()
    }

    /// Stop, or Send with the default. Command-Return comes straight here.
    private func actionButtonTapped() {
        if showsStopButton {
            onCancel()
        } else {
            if voiceInput.isListening {
                voiceInput.stopBeforeSubmittingDraft()
            }
            onSend()
        }
    }

    /// Starts dictation once for a composer opened by the "New Chat with Voice" intent (#338),
    /// mirroring a mic tap. Gated so it fires a single time, only while the app is active and
    /// unlocked (the scene stays active under the app lock, so the microphone never starts
    /// behind it) and the mic is free; the reused tap path handles the mic/speech permission
    /// prompt and surfaces a clear error if access is denied, so a denied/undetermined mic
    /// degrades gracefully.
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
        voiceInput.apiClient = apiClient
        voiceInput.providerPreference = ComposerSTTProviderPreference.storedValue(sttProviderPreferenceRawValue)
        voiceInput.scheduleToggle(currentDraft: draftMessage) { newDraft in
            editDraft(newDraft)
        }
    }

    /// Hold recognized → start recording a voice note. Gated by the recording
    /// disabled conditions; stops dictation first if it's running.
    @MainActor
    private func startVoiceNoteRecording() {
        guard !isVoiceNoteRecordingDisabled, !voiceNoteRecorder.isRecording else { return }

        if voiceInput.isListening {
            voiceInput.stopKeepingTranscript()
        }
        voiceNoteCancelArmed = false
        Task { await voiceNoteRecorder.begin() }
    }

    /// Finger lifted (or max duration hit). Cancels if slid up past the threshold,
    /// otherwise stops and sends the clip.
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

        Task { @MainActor in
            await Task.yield()
            guard canFocusTextView else { return }
            isFocused = true
        }
    }

    private func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.userCancelled.rawValue
    }
}
