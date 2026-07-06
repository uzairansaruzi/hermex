import SwiftUI
import HermexCore

public struct HermexChatScreen: View {
    private let state: HermexChatState
    private let onEvent: (HermexUIEvent) -> Void
    @State private var composerInset: CGFloat = 132

    public init(state: HermexChatState, onEvent: @escaping (HermexUIEvent) -> Void = { _ in }) {
        self.state = state
        self.onEvent = onEvent
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                chatHeader

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HermexLayoutContract.chatTranscriptMessageSpacing) {
                        ForEach(state.messages, id: \.stableId) { message in
                            messageBlock(message)
                        }

                        if state.stream.isStreaming {
                            streamingIndicator
                        }
                    }
                    .padding(.horizontal, HermexLayoutContract.chatTranscriptHorizontalPadding)
                    .padding(.top, HermexLayoutContract.chatTranscriptTopPadding)
                }
                .hermexComposerBottomReserve(composerInset)
            }

            LinearGradient(
                colors: [.clear, HermexUIColors.systemBackground.opacity(0.94), HermexUIColors.systemBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: composerInset + HermexLayoutContract.composerGradientTopPadding)
            .allowsHitTesting(false)

            HermexMeasuredBottomInset(measuredHeight: $composerInset) {
                VStack(spacing: HermexLayoutContract.pendingPromptBottomSpacing) {
                    pendingPromptStack
                    HermexComposerSurface(
                        state: state.composer,
                        stream: state.stream,
                        showsTurnActions: state.messages.last?.role == "assistant" && !state.stream.isStreaming,
                        onEvent: onEvent
                    )
                }
            }
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 14) {
            HermexCircleIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Back",
                action: { onEvent(.openRoute(.sessions)) }
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(state.composer.selectedWorkspace ?? state.session?.workspace ?? "workspace")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state.isViewingCachedData {
                    Text("Cached transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HermexIconCluster {
                HermexCircleIconButton(
                    systemImage: "folder",
                    accessibilityLabel: "Files",
                    action: { onEvent(.openRoute(.workspace)) }
                )
                HermexCircleIconButton(
                    systemImage: "arrow.triangle.branch",
                    accessibilityLabel: "Git",
                    action: { onEvent(.openRoute(.git)) }
                )
                HermexCircleIconButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: "Refresh",
                    action: { onEvent(.refresh) }
                )
            }
        }
        .padding(.horizontal, HermexLayoutContract.chatTopBarHorizontalPadding)
        .padding(.vertical, HermexLayoutContract.chatTopBarVerticalPadding)
        .frame(minHeight: HermexLayoutContract.chatTopBarHeight)
    }

    private func messageBlock(_ message: HermexChatMessageDTO) -> some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 7) {
            if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                transcriptAccessory(title: "Thinking", text: reasoning, systemImage: "brain.head.profile")
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                transcriptAccessory(title: "Tool calls", text: "\(toolCalls.count) item(s)", systemImage: "hammer")
            }

            HStack {
                if message.role == "user" { Spacer(minLength: 42) }
                Text(message.content ?? message.text ?? "")
                    .font(.body)
                    .hermexTextSelectionEnabled()
                    .padding(.horizontal, message.role == "user" ? 14 : 0)
                    .padding(.vertical, message.role == "user" ? 10 : 0)
                    .background(
                        message.role == "user"
                            ? HermexUIColors.secondarySystemBackground
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                if message.role != "user" { Spacer(minLength: 42) }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }

    private func transcriptAccessory(title: String, text: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var streamingIndicator: some View {
        Label(state.stream.liveToolActivity ?? "Responding", systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var pendingPromptStack: some View {
        VStack(spacing: 8) {
            if let approval = state.pendingApproval {
                approvalPrompt(approval)
            }
            if let clarification = state.pendingClarification {
                clarificationPrompt(clarification)
            }
        }
        .padding(.horizontal, HermexLayoutContract.pendingPromptHorizontalPadding)
    }

    private func approvalPrompt(_ approval: HermexApprovalPrompt) -> some View {
        HermexGlassPanel(cornerRadius: HermexLayoutContract.pendingPromptCornerRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Label(approval.title ?? "Approval required", systemImage: "checkmark.shield")
                    .font(.headline.weight(.semibold))
                if let command = approval.command, !command.isEmpty {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(3)
                }
                if let details = approval.details, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                HStack {
                    Button("Deny") { onEvent(.approval("deny")) }
                    Spacer()
                    Button("Approve") { onEvent(.approval("approve")) }
                        .fontWeight(.semibold)
                }
            }
            .padding(14)
        }
    }

    private func clarificationPrompt(_ clarification: HermexClarificationPrompt) -> some View {
        HermexGlassPanel(cornerRadius: HermexLayoutContract.pendingPromptCornerRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Clarification", systemImage: "questionmark.bubble")
                    .font(.headline.weight(.semibold))
                Text(clarification.question)
                    .font(.callout)
                if !clarification.options.isEmpty {
                    HStack {
                        ForEach(clarification.options, id: \.self) { option in
                            Button(option) { onEvent(.clarify(option)) }
                        }
                    }
                }
                if !clarification.draft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    Button("Send draft") { onEvent(.clarify(clarification.draft)) }
                }
            }
            .padding(14)
        }
    }
}

private extension View {
    @ViewBuilder
    func hermexComposerBottomReserve(_ height: CGFloat) -> some View {
#if SKIP
        self.padding(.bottom, height)
#else
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: height)
        }
#endif
    }

    @ViewBuilder
    func hermexTextSelectionEnabled() -> some View {
#if SKIP
        self
#else
        self.textSelection(.enabled)
#endif
    }
}

public struct HermexComposerSurface: View {
    private let state: HermexComposerState
    private let stream: HermexStreamState
    private let showsTurnActions: Bool
    private let onEvent: (HermexUIEvent) -> Void

    public init(
        state: HermexComposerState,
        stream: HermexStreamState,
        showsTurnActions: Bool = false,
        onEvent: @escaping (HermexUIEvent) -> Void = { _ in }
    ) {
        self.state = state
        self.stream = stream
        self.showsTurnActions = showsTurnActions
        self.onEvent = onEvent
    }

    public var body: some View {
        VStack(spacing: HermexLayoutContract.composerContainerSpacing) {
            HermexGlassPanel(cornerRadius: composerCornerRadius) {
                VStack(spacing: 0) {
                    if state.isRecordingVoice {
                        composerStatusBar(text: "Recording voice", systemImage: "waveform")
                    }

                    if !state.attachments.isEmpty {
                        attachmentStrip
                    }

                    Text(state.draft.isEmpty ? "Message Hermex" : state.draft)
                        .foregroundStyle(state.draft.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HermexLayoutContract.composerSurfaceHorizontalPadding)
                        .padding(.vertical, textVerticalPadding)

                    HStack(spacing: HermexLayoutContract.composerControlSpacing) {
                        Button { onEvent(.attach) } label: {
                            Image(systemName: "plus")
                                .frame(width: HermexLayoutContract.composerPlusButtonSize, height: HermexLayoutContract.composerPlusButtonSize)
                        }
                        modelControl
                        if state.showsReasoningControl {
                            reasoningControl
                        }
                        Spacer()
                        Button { onEvent(state.isRecordingVoice ? .stopVoice : .startVoice) } label: { Image(systemName: "waveform") }
                        Button { onEvent(stream.isStreaming ? .cancelStream : .sendDraft) } label: {
                            Image(systemName: stream.isStreaming ? "stop.fill" : "arrow.up")
                                .frame(width: HermexLayoutContract.composerActionButtonSize, height: HermexLayoutContract.composerActionButtonSize)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, HermexLayoutContract.composerSurfaceHorizontalPadding)
                    .padding(.top, HermexLayoutContract.composerSurfaceTopPadding)
                    .padding(.bottom, HermexLayoutContract.composerSurfaceBottomPadding)
                }
            }

            HStack(spacing: HermexLayoutContract.composerSecondaryBarSpacing) {
                workspaceControl
                profileControl
                Spacer()
            }

            if showsTurnActions {
                HStack(spacing: HermexLayoutContract.composerQuickActionSpacing) {
                    quickAction("Undo", .undo)
                    quickAction("Retry", .retry)
                    quickAction("Compress", .compress)
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, HermexLayoutContract.composerBottomAccessorySpacing)
    }

    private var isExpanded: Bool {
        state.draft.contains("\n") || state.draft.count > 44
    }

    private var composerCornerRadius: CGFloat {
        isExpanded ? HermexLayoutContract.composerCornerRadiusExpanded : HermexLayoutContract.composerCornerRadiusCollapsed
    }

    private var textVerticalPadding: CGFloat {
        isExpanded ? HermexLayoutContract.composerTextVerticalPaddingExpanded : HermexLayoutContract.composerTextVerticalPaddingCollapsed
    }

    @ViewBuilder
    private var modelControl: some View {
        if state.availableModels.isEmpty {
            Button { onEvent(.selectModel) } label: {
                modelLabel
            }
        } else {
            Menu {
                ForEach(state.availableModels) { model in
                    Button(model.displayName) {
                        onEvent(.chooseModel(model))
                    }
                }
            } label: {
                modelLabel
            }
        }
    }

    private var modelLabel: some View {
        Text(state.selectedModel ?? "model")
            .lineLimit(1)
            .frame(maxWidth: HermexLayoutContract.composerModelControlMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var reasoningControl: some View {
        if state.supportedReasoningEfforts.isEmpty {
            Button { onEvent(.selectReasoning) } label: {
                reasoningLabel
            }
        } else {
            Menu {
                ForEach(state.supportedReasoningEfforts, id: \.self) { effort in
                    Button(effort) {
                        onEvent(.chooseReasoningEffort(effort))
                    }
                }
            } label: {
                reasoningLabel
            }
        }
    }

    private var reasoningLabel: some View {
        Label(state.selectedReasoningEffort ?? "Reasoning", systemImage: "brain")
            .lineLimit(1)
            .frame(width: HermexLayoutContract.composerReasoningControlWidth, alignment: .leading)
    }

    @ViewBuilder
    private var workspaceControl: some View {
        if state.availableWorkspaces.isEmpty {
            Button { onEvent(.selectWorkspace) } label: {
                HermexPillLabel(state.selectedWorkspace ?? "Home", systemImage: "folder")
            }
        } else {
            Menu {
                ForEach(state.availableWorkspaces) { workspace in
                    Button(workspace.name ?? workspace.path) {
                        onEvent(.chooseWorkspace(workspace))
                    }
                }
            } label: {
                HermexPillLabel(state.selectedWorkspace ?? "Home", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private var profileControl: some View {
        if state.availableProfiles.isEmpty {
            Button { onEvent(.selectProfile) } label: {
                HermexPillLabel(state.selectedProfile ?? "default", systemImage: "person.crop.circle")
            }
        } else {
            Menu {
                ForEach(state.availableProfiles) { profile in
                    Button(profile.title) {
                        onEvent(.chooseProfile(profile))
                    }
                }
            } label: {
                HermexPillLabel(state.selectedProfile ?? "default", systemImage: "person.crop.circle")
            }
        }
    }

    private func composerStatusBar(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HermexLayoutContract.composerSurfaceHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(state.attachments) { attachment in
                    Label(attachment.name ?? attachment.path ?? "Attachment", systemImage: attachment.isImage == true ? "photo" : "doc")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: HermexLayoutContract.composerAttachmentStripHeight)
                        .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, HermexLayoutContract.composerSurfaceHorizontalPadding)
            .padding(.top, 9)
        }
    }

    private func quickAction(_ title: String, _ event: HermexUIEvent) -> some View {
        Button {
            onEvent(event)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
    }
}
