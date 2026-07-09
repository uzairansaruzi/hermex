import SwiftUI
import UIKit
import PhotosUI

private struct ComposerStatusView: View {
    let text: String
    let isError: Bool
    let isDismissible: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(AppFont.caption())
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

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

struct MessageComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @ScaledMetric(relativeTo: .footnote) private var actionIconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var actionButtonSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title3) private var plusIconSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var plusButtonSize: CGFloat = 28

    @Binding var draftMessage: String
    @Binding var isFocused: Bool
    let isSending: Bool
    let isCompressingSession: Bool
    let isWaitingForStream: Bool
    let isCancellingStream: Bool
    let isOfflineReadOnly: Bool
    let isChromeCompact: Bool
    let errorMessage: String?
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
    let agentCommands: [AgentCommand]
    let profileOptions: [ProfileSummary]
    let isSingleProfileMode: Bool
    let selectedProfileName: String?
    let selectedProfileTitle: String
    let isLoadingModels: Bool
    let selectedReasoningEffort: String?
    /// Model-aware effort vocabulary; `nil` → full static list (issue #18).
    let supportedReasoningEfforts: [String]?
    /// When false the model has no effort control — hide the reasoning menu.
    let showsReasoningControl: Bool
    let isUpdatingConfiguration: Bool
    let pendingAttachments: [PendingAttachment]
    let isUploadingAttachment: Bool
    let isSendingVoiceNote: Bool
    /// When true, dictation auto-starts once this composer appears with the app active —
    /// the "New Chat with Voice" App Intent (#338). Defaults to false for normal composers.
    let autoStartsVoiceInput: Bool
    let apiClient: APIClient?
    let uploadAttachmentErrorMessage: String?
    let onSend: () -> Void
    let onSendVoiceNote: (Data, String) -> Void
    let onCancel: () -> Void
    let onSelectModel: (ModelCatalogOption) -> Void
    let onModelPickerOpen: () async -> Void
    let onLoadWorkspaceSuggestions: (String) async -> Void
    let onWorkspaceRegistryChanged: () async -> Void
    let onLoadPersonalitySuggestions: () async -> Void
    let onLoadSkillSuggestions: () async -> Void
    let onSelectWorkspace: (String) async -> Void
    let onSelectProfile: (ProfileSummary) -> Void
    let onSelectReasoningEffort: (String) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPhotoItemSelected: (PhotosPickerItem) -> Void
    let onFileURLsSelected: ([URL]) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPreviewAttachment: (PendingAttachment) -> Void
    let onDismissUploadAttachmentError: () -> Void
    let onSelectGitBranch: (GitCheckoutTarget) -> Void
    let onCreateGitBranch: (GitCheckoutTarget) -> Void
    let onRefreshGitBranches: () -> Void

    @State private var textFieldHeight: CGFloat = 0
    @State private var textInputHeight: CGFloat = 22
    @State private var noticeMessage: String?
    @State private var showsAllModelsSheet = false
    @State private var showsWorkspaceSheet = false
    @State private var optimisticWorkspacePath: String?
    @State private var favoriteModelKeys = ModelFavoritesStore.shared.favoriteKeys
    @State private var recentModelKeys = ModelRecentsStore.shared.recentKeys
    @State private var keyboardIsVisible = false
    @State private var shouldRestoreFocusAfterPresentation = false
    @State private var shouldRestoreFocusAfterUpload = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var voiceInput = ComposerVoiceInputController()
    @State private var voiceNoteRecorder = ComposerVoiceNoteRecorder()
    @State private var voiceNoteCancelArmed = false
    @State private var didAutoStartVoiceInput = false
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue

    private var showsSlashAutocomplete: Bool {
        let query = draftMessage.drop(while: { $0.isWhitespace })
        guard query.hasPrefix("/") else { return false }

        let parsed = ParsedSlashQuery(query: draftMessage)
        if let command = parsed.command,
           command.subArgs == .none,
           hasWhitespaceAfterSlashCommand(command.name, in: String(query)) {
            return false
        }

        if SlashSkillFormatter.skill(named: parsed.commandName, in: skillSuggestions) != nil,
           hasWhitespaceAfterSlashCommand(parsed.commandName, in: String(query)) {
            return false
        }

        if AgentSlashCommandSuggestion.command(named: parsed.commandName, in: agentCommands) != nil,
           hasWhitespaceAfterSlashCommand(parsed.commandName, in: String(query)) {
            return false
        }

        if parsed.commandName.lowercased() == "skills",
           SlashSkillFormatter.invocation(from: parsed.argQuery, suggestions: skillSuggestions) != nil {
            return false
        }

        if parsed.command?.subArgs == .goalActions,
           parsed.isSubArgMode,
           !parsed.argQuery.isEmpty,
           !SlashCommandCatalog.goalActions.contains(where: {
               $0.hasPrefix(parsed.argQuery.lowercased())
           }) {
            return false
        }

        return true
    }

    private func hasWhitespaceAfterSlashCommand(_ commandName: String, in query: String) -> Bool {
        let prefix = "/\(commandName)"
        guard query.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        let afterCommand = query.dropFirst(prefix.count)
        return afterCommand.first?.isWhitespace == true
    }

    private var parsedSlashQuery: ParsedSlashQuery {
        ParsedSlashQuery(query: draftMessage)
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

    var body: some View {
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
                        onDismiss: onDismissUploadAttachmentError
                    )
                }

                Group {
                    if showsSlashAutocomplete {
                        SlashCommandAutocompleteView(
                            query: draftMessage,
                            selectedModelID: selectedModelID,
                            modelGroups: modelGroups,
                            workspaceRoots: workspaceRoots,
                            workspaceSuggestions: workspaceSuggestions,
                            personalitySuggestions: personalitySuggestions,
                            skillSuggestions: skillSuggestions,
                            agentCommands: agentCommands,
                            selectedReasoningEffort: selectedReasoningEffort,
                            onSelectCommand: { command in
                                draftMessage = "/\(command.name) "
                            },
                            onSelectSkillCommand: { skill in
                                draftMessage = "/\(skill.slashName) "
                            },
                            onSelectAgentCommand: { command in
                                draftMessage = "/\(command.name) "
                            },
                            onSelectSkillSubArg: { skill in
                                draftMessage = "/skills \(skill.slashName) "
                            },
                            onSelectSubArg: { subArg in
                                let parsed = ParsedSlashQuery(query: draftMessage)
                                draftMessage = "/\(parsed.commandName) \(subArg)"
                            },
                            onDismiss: {
                                draftMessage = ""
                            }
                        )
                        .padding(.horizontal)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsSlashAutocomplete)

                VStack(spacing: 0) {
                    ComposerAttachmentStripView(
                        attachments: pendingAttachments,
                        onRemove: onRemoveAttachment,
                        onPreview: onPreviewAttachment
                    )

                    ComposerTextInputView(
                        text: $draftMessage,
                        isFocused: $isFocused,
                        inputHeight: $textInputHeight,
                        measuredHeight: $textFieldHeight,
                        isDisabled: isOfflineReadOnly,
                        verticalPadding: textFieldVerticalPadding,
                        onPasteFileProviders: onPasteFileProviders,
                        onPasteFileURLs: onPasteFileURLs,
                        onPasteImageProviders: onPasteImageProviders,
                        onPasteImages: onPasteImages
                    )

                    HStack(alignment: .center, spacing: 12) {
                        composerPlusMenu

                        modelMenu

                        if showsReasoningControl {
                            reasoningMenu
                        }

                        Spacer(minLength: 0)

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

                        Button(action: actionButtonTapped) {
                            actionButtonLabel
                                .frame(width: actionButtonSize, height: actionButtonSize)
                                .background(actionButtonBackground)
                                .foregroundStyle(actionButtonForeground)
                                .clipShape(Circle())
                                .chatMinimumHitTarget(in: Circle())
                        }
                        .buttonStyle(.chatTactile(.icon))
                        .disabled(isActionButtonDisabled)
                        .accessibilityLabel(showsStopButton ? "Stop response" : "Send")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 6)
                .padding(.horizontal)

                secondaryBar
                    .padding(.horizontal)
                    .padding(.bottom, 7)
                    .animation(ChatMotion.composerChrome(reduceMotion: reduceMotion), value: showsSecondaryChrome)
            }
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
        .task(id: slashAutocompleteLoadKey) {
            await loadSlashAutocompleteSubArgsIfNeeded()
        }
        .task {
            // Cold path: the composer appears already active (the usual case for the
            // "New Chat with Voice" intent once its session is created) — start here.
            autoStartVoiceInputIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                voiceInput.stopBeforeSubmittingDraft()
                // Backgrounding stops the recorder's run-loop ticker, so cancel
                // the in-flight recording rather than leave it silently stalled.
                cancelVoiceNote()
            } else {
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
        .sheet(isPresented: $showsAllModelsSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            ComposerModelPickerSheet(
                modelGroups: modelGroups,
                selectedModelID: selectedModelID,
                selectedModelProviderID: selectedModelProviderID,
                favoriteModelKeys: favoriteModelKeys,
                recentModelKeys: recentModelKeys,
                onSelect: { option in
                    selectModel(option)
                    showsAllModelsSheet = false
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
                managementServer: isOfflineReadOnly ? nil : workspaceManagementServer,
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
                shouldRestoreFocusAfterUpload = false
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
        .onChange(of: showPhotoPicker) { _, isPresented in
            if !isPresented, selectedPhotoItems.isEmpty {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: showFileImporter) { _, isPresented in
            if !isPresented {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: isUploadingAttachment) { _, isUploading in
            if !isUploading {
                restoreFocusAfterUploadIfNeeded()
            }
        }
        .onChange(of: uploadAttachmentErrorMessage) { _, newValue in
            if newValue != nil {
                shouldRestoreFocusAfterUpload = false
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
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
    }

    @ViewBuilder
    private var actionButtonLabel: some View {
        if isSending || isCancellingStream || isCompressingSession {
            ProgressView()
                .tint(actionButtonForeground)
                .scaleEffect(0.82)
        } else if showsStopButton {
            Image(systemName: "stop.fill")
                .font(.system(size: actionIconSize, weight: .semibold))
        } else {
            Image(systemName: "arrow.up")
                .font(.system(size: actionIconSize, weight: .semibold))
        }
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
        ChatUIKitMenuButton(horizontalPadding: 8, verticalPadding: 8) {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .regular))
                .foregroundStyle(metaControlColor)
                .frame(width: plusButtonSize, height: plusButtonSize)
                .chatMinimumHitTarget(in: Circle())
        } menu: {
            composerOptionsMenu()
        }
        .tint(metaControlColor)
        .disabled(isConfigurationControlDisabled)
        .accessibilityLabel("Composer options")
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, matching: .images)
        .onChange(of: selectedPhotoItems) {
            let items = selectedPhotoItems
            guard !items.isEmpty else { return }
            deferFocusRestoreUntilUploadCompletes()
            selectedPhotoItems.removeAll()
            for item in items {
                onPhotoItemSelected(item)
            }
        }
    }

    private func composerOptionsMenu() -> UIMenu {
        UIMenu(title: "", children: [
            UIMenu(
                title: String(localized: "Attach"),
                options: [.displayInline],
                children: [
                    UIAction(
                        title: String(localized: "Attach File"),
                        image: UIImage(systemName: "paperclip")
                    ) { _ in
                        Task { @MainActor in
                            prepareForComposerPresentation()
                            showFileImporter = true
                        }
                    },
                    UIAction(
                        title: String(localized: "Photos"),
                        image: UIImage(systemName: "photo.on.rectangle")
                    ) { _ in
                        Task { @MainActor in
                            prepareForComposerPresentation()
                            showPhotoPicker = true
                        }
                    }
                ]
            )
        ])
    }

    @ViewBuilder
    private var secondaryBar: some View {
        if showsSecondaryChrome {
            if usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        workspaceSelector

                        // Single-profile mode: the server rejects profile switches,
                        // so the selector could only no-op or error (#24).
                        if !isSingleProfileMode {
                            profileSelector
                        }

                        gitBranchPicker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ContextWindowIndicatorView(snapshot: contextWindowSnapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            } else {
                HStack(spacing: 8) {
                    workspaceSelector

                    if !isSingleProfileMode {
                        profileSelector
                    }

                    gitBranchPicker

                    Spacer(minLength: 0)

                    ContextWindowIndicatorView(snapshot: contextWindowSnapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var gitBranchPicker: some View {
        if gitViewModel.hasRepository {
            GitBranchPickerButton(
                currentBranch: gitViewModel.currentBranchName,
                branches: gitViewModel.branches,
                isLoading: gitViewModel.isLoadingBranches,
                isSwitching: gitViewModel.isSwitchingBranch,
                isDisabled: isOfflineReadOnly || isWaitingForStream,
                onSelect: onSelectGitBranch,
                onCreate: onCreateGitBranch,
                onRefresh: onRefreshGitBranches
            )
        }
    }

    private var showsSecondaryChrome: Bool {
        !keyboardIsVisible && !isChromeCompact
    }

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var metaControlFont: Font {
        AppFont.footnote()
    }

    private var metaChevronFont: Font {
        AppFont.caption2()
    }

    private var modelControlMaxWidth: CGFloat {
        usesAccessibilityLayout ? 156 : 132
    }

    private var reasoningControlWidth: CGFloat {
        usesAccessibilityLayout ? 126 : 104
    }

    private var secondaryBarLineLimit: Int {
        usesAccessibilityLayout ? 2 : 1
    }

    private var secondaryBarVerticalPadding: CGFloat {
        usesAccessibilityLayout ? 10 : 8
    }

    private var secondaryBarHorizontalPadding: CGFloat {
        usesAccessibilityLayout ? 16 : 14
    }

    private var workspaceSelector: some View {
        ComposerWorkspaceSelectorButton(
            title: workspaceTitle,
            isDisabled: isConfigurationControlDisabled,
            lineLimit: secondaryBarLineLimit,
            verticalPadding: secondaryBarVerticalPadding,
            horizontalPadding: secondaryBarHorizontalPadding,
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
            isDisabled: isConfigurationControlDisabled,
            lineLimit: secondaryBarLineLimit,
            verticalPadding: secondaryBarVerticalPadding,
            horizontalPadding: secondaryBarHorizontalPadding,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectProfile: onSelectProfile
        )
    }

    private var modelMenu: some View {
        ComposerModelMenu(
            modelGroups: modelGroups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: isLoadingModels,
            favoriteModelKeys: favoriteModelKeys,
            recentModelKeys: recentModelKeys,
            isDisabled: isConfigurationControlDisabled,
            maxWidth: modelControlMaxWidth,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectModel: selectModel
        ) {
            prepareForComposerPresentation()
            showsAllModelsSheet = true
        }
    }

    private var reasoningMenu: some View {
        ComposerReasoningMenu(
            selectedReasoningEffort: selectedReasoningEffort,
            supportedEfforts: supportedReasoningEfforts,
            reasoningTitle: reasoningTitle,
            isDisabled: isConfigurationControlDisabled,
            width: reasoningControlWidth,
            color: metaControlColor,
            controlFont: metaControlFont,
            chevronFont: metaChevronFont,
            onSelectReasoningEffort: onSelectReasoningEffort
        )
    }

    private func selectModel(_ option: ModelCatalogOption) {
        recentModelKeys = ModelRecentsStore.shared.recordRecent(option)
        onSelectModel(option)
    }

    private var composerStatus: (text: String, isError: Bool, isDismissible: Bool)? {
        if isOfflineReadOnly {
            return (String(localized: "Reconnect to send messages."), false, false)
        } else if isWaitingForStream && isCancellingStream {
            return (String(localized: "Stopping response..."), false, false)
        } else if isCompressingSession {
            return (String(localized: "Compressing context..."), false, false)
        } else if let uploadAttachmentErrorMessage {
            return (uploadAttachmentErrorMessage, true, true)
        } else if isSendingVoiceNote {
            return (String(localized: "Sending voice note..."), false, false)
        } else if isUploadingAttachment {
            return (String(localized: "Uploading attachment..."), false, false)
        } else if let errorMessage {
            return (errorMessage, true, false)
        } else if let configurationErrorMessage {
            return (configurationErrorMessage, true, false)
        } else if isUpdatingConfiguration {
            return (String(localized: "Updating composer settings..."), false, false)
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
        isOfflineReadOnly || isSending || isCompressingSession || isWaitingForStream || isUpdatingConfiguration
    }

    private var isVoiceInputDisabled: Bool {
        if voiceInput.isListening {
            return false
        }

        return isOfflineReadOnly
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
        isOfflineReadOnly
            || isSending
            || isSendingVoiceNote
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

    private var actionButtonBackground: Color {
        if PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !isActionButtonDisabled
        ) {
            return HeaderLogoColor.color(for: headerLogoColorHex)
        }

        if isActionButtonDisabled {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }

        return colorScheme == .dark ? .white : .black
    }

    private var actionButtonForeground: Color {
        if PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !isActionButtonDisabled
        ) {
            return HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
        }

        if isActionButtonDisabled {
            return Color(.secondaryLabel)
        }

        return colorScheme == .dark ? .black : .white
    }

    private var isComposerExpanded: Bool {
        draftMessage.contains("\n") || textFieldHeight > 44
    }

    private var composerCornerRadius: CGFloat {
        isComposerExpanded ? 26 : 22
    }

    private var textFieldVerticalPadding: CGFloat {
        isComposerExpanded ? 12 : 14
    }

    private var reasoningTitle: String {
        guard let selectedReasoningEffort else {
            return String(localized: "Reasoning")
        }

        return ReasoningEffortOption.title(for: selectedReasoningEffort)
    }

    private var trimmedDraftMessage: String {
        draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsStopButton: Bool {
        isWaitingForStream && trimmedDraftMessage.isEmpty
    }

    private var isActionButtonDisabled: Bool {
        if isOfflineReadOnly {
            return true
        }

        if showsStopButton {
            return isCancellingStream
        }

        return trimmedDraftMessage.isEmpty
            || isSending
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

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
    /// the mic is free; the reused tap path handles the mic/speech permission prompt and surfaces
    /// a clear error if access is denied, so a denied/undetermined mic degrades gracefully.
    @MainActor
    private func autoStartVoiceInputIfNeeded() {
        guard autoStartsVoiceInput, !didAutoStartVoiceInput else { return }
        guard scenePhase == .active else { return }
        didAutoStartVoiceInput = true
        guard !voiceInput.isListening, !isVoiceInputDisabled else { return }
        toggleVoiceInput()
    }

    @MainActor
    private func toggleVoiceInput() {
        voiceInput.apiClient = apiClient
        voiceInput.providerPreference = ComposerSTTProviderPreference.storedValue(sttProviderPreferenceRawValue)
        voiceInput.locale = .current
        Task {
            await voiceInput.toggle(currentDraft: draftMessage) { newDraft in
                draftMessage = newDraft
            }
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
        !isOfflineReadOnly && !isUploadingAttachment && uploadAttachmentErrorMessage == nil
    }

    private func prepareForComposerPresentation() {
        shouldRestoreFocusAfterPresentation = isFocused
        if isFocused {
            isFocused = false
        }
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
        shouldRestoreFocusAfterUpload = true
    }

    private func restoreFocusAfterUploadIfNeeded() {
        guard shouldRestoreFocusAfterUpload else { return }
        shouldRestoreFocusAfterUpload = false
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
