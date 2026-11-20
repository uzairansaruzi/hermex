import SwiftUI

struct MessageBubbleView: View {
    @State private var responseIsVisible = false
    @State private var userBubbleFold: UserBubbleFold?
    @State private var userBubbleIsExpanded = false
    @State private var settledReplyMedia = SettledReplyMedia()
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.composerChipCatalog) private var composerChipCatalog
    @Environment(\.chatWorkspaceRoot) private var chatWorkspaceRoot
    @Environment(\.resolvesBareMediaPaths) private var resolvesBareMediaPaths
    @AppStorage(ChatTranscriptDisplaySettings.hidesAttachmentPathsKey) private var hidesAttachmentPaths = true
    @AppStorage(ChatTranscriptDisplaySettings.showsResponseSpeedKey) private var showsResponseSpeed = false

    let textOnly: Bool
    let message: ChatMessage
    let loadAttachmentImage: ((String) async -> Data?)?
    let attachmentAudio: AttachmentAudioSource?
    let loadTranscriptMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadTranscriptMediaData: ((TranscriptMediaReference) async -> Data?)?
    let transcriptMediaCacheNamespace: String
    let localAttachmentPreviews: [String: Data]?
    let onPreviewAttachment: ((MessageAttachmentPreview, [MessageAttachmentPreview]) -> Void)?
    let onPreviewTranscriptMedia: ((TranscriptMediaReference, [TranscriptMediaReference]) -> Void)?
    let isStreaming: Bool
    let liveTokensPerSecond: Double?
    let onAskHermex: (String) -> Void
    let contextMenuActions: [ChatMessageActionItem]
    let isQueued: Bool

    init(
        message: ChatMessage,
        loadAttachmentImage: ((String) async -> Data?)? = nil,
        attachmentAudio: AttachmentAudioSource? = nil,
        loadTranscriptMediaImage: ((TranscriptMediaReference) async -> Data?)? = nil,
        loadTranscriptMediaData: ((TranscriptMediaReference) async -> Data?)? = nil,
        transcriptMediaCacheNamespace: String,
        localAttachmentPreviews: [String: Data]? = nil,
        onPreviewAttachment: ((MessageAttachmentPreview, [MessageAttachmentPreview]) -> Void)? = nil,
        onPreviewTranscriptMedia: ((TranscriptMediaReference, [TranscriptMediaReference]) -> Void)? = nil,
        isStreaming: Bool = false,
        liveTokensPerSecond: Double? = nil,
        onAskHermex: @escaping (String) -> Void = { _ in },
        contextMenuActions: [ChatMessageActionItem] = [],
        textOnly: Bool = false,
        isQueued: Bool = false
    ) {
        self.textOnly = textOnly
        self.isQueued = isQueued
        self.message = message
        self.loadAttachmentImage = loadAttachmentImage
        self.attachmentAudio = attachmentAudio
        self.loadTranscriptMediaImage = loadTranscriptMediaImage
        self.loadTranscriptMediaData = loadTranscriptMediaData
        self.transcriptMediaCacheNamespace = transcriptMediaCacheNamespace
        self.localAttachmentPreviews = localAttachmentPreviews
        self.onPreviewAttachment = onPreviewAttachment
        self.onPreviewTranscriptMedia = onPreviewTranscriptMedia
        self.isStreaming = isStreaming
        self.liveTokensPerSecond = liveTokensPerSecond
        self.onAskHermex = onAskHermex
        self.contextMenuActions = contextMenuActions
    }

    var body: some View {
        let _ = RenderProbe.hit(.messageBubble)
        if isLocalNotice {
            localNoticeRow
        } else if isLocalAssistant {
            localAssistantRow
        } else if message.isSteerMessage {
            steerBubble
        } else if isUserMessage {
            userMessageRow
        } else if textOnly {
            MarkdownRenderer(content: message.content ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            assistantMessageRow
        }
    }

    private var userMessageRow: some View {
        let previewURL = linkPreviewURL
        let text = userBubbleText
        let hasVisibleText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let bodyFont = userBubbleBodyFont
        let mayFold = hasVisibleText && UserBubbleFoldPolicy.mayFold(text: text, font: bodyFont)
        let folds = mayFold && userBubbleFold?.folds(text, at: dynamicTypeSize) == true

        return VStack(alignment: .trailing, spacing: 8) {
            if !textOnly, let attachments = message.attachments, !attachments.isEmpty {
                attachmentPreviews
            }

            if hasVisibleText || previewURL != nil {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: userBubbleLeadingGutter)
                    VStack(alignment: .trailing, spacing: 8) {
                        if hasVisibleText {
                            userBubble(text: text, folds: folds, bodyFont: bodyFont)
                        }
                        linkPreview(previewURL)
                    }
                    .chatMessageContextMenu(contextMenuActions)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background {
            if mayFold {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth in
                        measureUserBubbleFold(text, rowWidth: rowWidth, bodyFont: bodyFont)
                    }
                    .onChange(of: text) {
                        measureUserBubbleFold(text, rowWidth: userBubbleFold?.rowWidth, bodyFont: bodyFont)
                    }
                    .onChange(of: dynamicTypeSize) {
                        measureUserBubbleFold(text, rowWidth: userBubbleFold?.rowWidth, bodyFont: bodyFont)
                    }
                    .onChange(of: AppFontSettings.shared.family) {
                        measureUserBubbleFold(text, rowWidth: userBubbleFold?.rowWidth, bodyFont: bodyFont)
                    }
            }
        }
    }

    private func measureUserBubbleFold(_ text: String, rowWidth: CGFloat?, bodyFont: UIFont) {
        guard let rowWidth else { return }
        let lineCount = UserBubbleFoldPolicy.lineCount(
            text: text,
            width: rowWidth - userBubbleLeadingGutter - 2 * Self.userBubbleHorizontalPadding,
            font: bodyFont,
            limit: UserBubbleFoldPolicy.maximumUnfoldedLines + 1
        )
        userBubbleFold = UserBubbleFold(
            text: text,
            rowWidth: rowWidth,
            dynamicTypeSize: dynamicTypeSize,
            wrapsPastLimit: UserBubbleFoldPolicy.folds(lineCount: lineCount)
        )
    }

    private var steerBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label {
                Text("Steer")
                    .font(AppFont.caption(weight: .semibold))
            } icon: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.appSecondary)

            if !message.steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message.steerText)
                    .font(AppFont.callout())
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                Color.accentColor.opacity(colorScheme == .dark ? 0.45 : 0.3),
                                lineWidth: 0.5
                            )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Steering hint"))
        .accessibilityValue(message.steerText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var assistantMessageRow: some View {
        let segments = TranscriptMediaSegmentCache.segments(
            in: messageText,
            workspaceRoot: chatWorkspaceRoot,
            resolvesBarePaths: resolvesBareMediaPaths,
            isStreaming: isStreaming
        )
        let onPreviewTranscriptMedia = onPreviewTranscriptMedia.map { preview in
            { (reference: TranscriptMediaReference) in preview(reference, segments.mediaReferences) }
        }

        return VStack(alignment: .leading, spacing: 6) {
            if showsAssistantTurnHeaderForThisMessage {
                assistantTurnHeader
            }

            if isStreaming {
                assistantContent(
                    segments: segments,
                    loadMediaImage: loadTranscriptMediaImage,
                    loadMediaData: loadTranscriptMediaData,
                    onPreviewMedia: onPreviewTranscriptMedia
                )
            } else {
                let media = settledReplyMedia.refreshed(
                    loadImage: loadTranscriptMediaImage,
                    loadData: loadTranscriptMediaData,
                    preview: onPreviewTranscriptMedia
                )
                ResponseTextSelection(
                    identity: messageText,
                    inputs: SettledReplyInputs(
                        workspaceRoot: chatWorkspaceRoot,
                        resolvesBarePaths: resolvesBareMediaPaths,
                        cacheNamespace: transcriptMediaCacheNamespace,
                        loadsMediaImages: loadTranscriptMediaImage != nil,
                        loadsMediaData: loadTranscriptMediaData != nil,
                        previewsMedia: onPreviewTranscriptMedia != nil
                    ),
                    collectsGlyphs: responseIsVisible,
                    onAskHermex: onAskHermex
                ) {
                    assistantContent(
                        segments: segments,
                        loadMediaImage: media.loadImage,
                        loadMediaData: media.loadData,
                        onPreviewMedia: media.preview
                    )
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
                    return viewport.intersects(CGRect(origin: .zero, size: geometry.size))
                } action: { responseIsVisible = $0 }
            }

            linkPreview(linkPreviewURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func assistantContent(
        segments: [TranscriptMediaSegment],
        loadMediaImage: ((TranscriptMediaReference) async -> Data?)?,
        loadMediaData: ((TranscriptMediaReference) async -> Data?)?,
        onPreviewMedia: ((TranscriptMediaReference) -> Void)?
    ) -> some View {
        if segments.containsTranscriptMedia {
            TranscriptMediaContentView(
                segments: segments,
                cacheNamespace: transcriptMediaCacheNamespace,
                loadMediaImage: loadMediaImage,
                loadMediaData: loadMediaData,
                onPreviewMedia: onPreviewMedia,
                isStreaming: isStreaming
            )
        } else {
            MarkdownRenderer(content: messageText, isStreaming: isStreaming)
        }
    }

    private var assistantTurnHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            if let speed = assistantResponseSpeedText {
                Text(speed)
                    .foregroundStyle(.appSecondary)
            }
        }
        .font(AppFont.footnote())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(assistantTurnHeaderAccessibilityLabel)
    }

    private var showsAssistantTurnHeaderForThisMessage: Bool {
        ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: message.role,
            hasTextContent: hasVisibleAssistantText,
            showsResponseSpeed: showsResponseSpeed,
            hasResponseSpeed: assistantResponseSpeedText != nil
        )
    }

    private var hasVisibleAssistantText: Bool {
        guard let content = message.content else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var assistantResponseSpeedText: String? {
        guard showsResponseSpeed else { return nil }
        return ResponseSpeedFormatter.compactText(isStreaming ? liveTokensPerSecond : message.turnTps)
    }

    private var assistantTurnHeaderAccessibilityLabel: String {
        guard let speed = assistantResponseSpeedAccessibilityText else {
            return String(localized: "Assistant")
        }
        return String(localized: "Assistant, \(speed)")
    }

    private var assistantResponseSpeedAccessibilityText: String? {
        guard showsResponseSpeed else { return nil }
        return ResponseSpeedFormatter.accessibilityText(isStreaming ? liveTokensPerSecond : message.turnTps)
    }

    private var localNoticeRow: some View {
        localStatusRow(
            iconName: "checkmark.circle.fill",
            iconColor: .green
        )
    }

    private var localAssistantRow: some View {
        localStatusRow(
            iconName: "command.circle.fill",
            iconColor: .accentColor
        )
    }

    private func localStatusRow(iconName: String, iconColor: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Circle())

            MarkdownRenderer(content: messageText, isStreaming: isStreaming)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.markdownTableEdgeFadeColor, nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.appMaterial(.thinMaterial), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.appSeparator).opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }

    private func userBubble(text: String, folds: Bool, bodyFont: UIFont) -> some View {
        let chips = textOnly ? [] : userBubbleChips(in: text)
        let isFolded = folds && !userBubbleIsExpanded

        return VStack(alignment: .leading, spacing: 6) {
            ComposerChipTextLine.text(text, tokens: chips, style: chipStyle)
                .font(AppFont.body())
                .lineLimit(isFolded ? UserBubbleFoldPolicy.visibleLines : nil)
                .textSelection(.enabled)
                .overlay(alignment: .bottom) {
                    if isFolded {
                        LinearGradient(
                            colors: [userBubbleBackground.opacity(0), userBubbleBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bodyFont.lineHeight)
                        .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(
                    chips.isEmpty
                        ? Text(verbatim: text)
                        : Text(verbatim: ComposerChipTokenizer.spokenText(in: text, tokens: chips))
                )

            if folds {
                userBubbleFoldToggle
            }
        }
        .padding(.horizontal, Self.userBubbleHorizontalPadding)
        .padding(.vertical, 8)
        .background(userBubbleBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(userBubbleForeground)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(userBubbleBorder, lineWidth: 0.5)
        )
    }

    private var userBubbleFoldToggle: some View {
        Button {
            chatDisclosureToggled()
            userBubbleIsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                if userBubbleIsExpanded {
                    Text("Show less")
                } else {
                    Text("Show more")
                }
                Image(systemName: userBubbleIsExpanded ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
            .font(AppFont.subheadline(weight: .semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.chatTactile(.compactControl))
        .foregroundStyle(.tint)
    }

    private func userBubbleChips(in text: String) -> [ComposerChipToken] {
        guard !composerChipCatalog.isEmpty else { return [] }
        return ComposerChipTokenizer.tokens(in: text, catalog: composerChipCatalog, isComplete: true)
    }

    private var chipStyle: ComposerChipTextStyle {
        ComposerChipTextStyle(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast,
            layoutDirection: layoutDirection,
            dynamicTypeSize: dynamicTypeSize,
            displayScale: displayScale,
            appearance: appearance
        )
    }

    private var linkPreviewURL: URL? {
        guard !textOnly, !isQueued else { return nil }
        return TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: isStreaming)
    }

    @ViewBuilder
    private func linkPreview(_ url: URL?) -> some View {
        if let url {
            TranscriptLinkPreviewView(url: url)
                .frame(maxWidth: 300)
        }
    }

    private var attachmentPreviews: some View {
        let allItems = attachmentsWithPreviews
        let audioItems = allItems.filter { attachmentAudio?.playsInline($0.attachment) == true }
        let gridItems = allItems.filter { attachmentAudio?.playsInline($0.attachment) != true }
        let columns = 2
        let spacing: CGFloat = 8
        let cellSize: CGFloat = 118
        let contentWidth = CGFloat(columns) * cellSize + CGFloat(columns - 1) * spacing

        return VStack(alignment: .trailing, spacing: spacing) {
            ForEach(audioItems.indices, id: \.self) { index in
                let attachment = audioItems[index].attachment
                inlineAudioPlayer(for: attachment, localData: audioItems[index].localData)
                .id(attachment.path ?? attachment.name ?? "\(index)")
                .frame(width: contentWidth, alignment: .trailing)
            }

            if !gridItems.isEmpty {
                attachmentGrid(
                    items: gridItems,
                    onPreview: onPreviewAttachment.map { preview in
                        { attachment, localData in preview((attachment, localData), gridItems) }
                    },
                    columns: columns,
                    cellSize: cellSize,
                    spacing: spacing,
                    width: contentWidth
                )
            }
        }
        .chatMessageContextMenu(contextMenuActions)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func attachmentGrid(
        items: [MessageAttachmentPreview],
        onPreview: ((MessageAttachment, Data?) -> Void)?,
        columns: Int,
        cellSize: CGFloat,
        spacing: CGFloat,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .trailing, spacing: spacing) {
            ForEach(0..<rowCount(items: items, columns: columns), id: \.self) { row in
                HStack(spacing: spacing) {
                    let start = row * columns
                    let end = min(start + columns, items.count)
                    ForEach(start..<end, id: \.self) { index in
                        let item = items[index]
                        GridAttachmentCell(
                            attachment: item.attachment,
                            localData: item.localData,
                            cacheNamespace: transcriptMediaCacheNamespace,
                            loadAttachmentImage: loadAttachmentImage,
                            onPreviewAttachment: onPreview,
                            size: cellSize
                        )
                        .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    private func audioDisplayName(for attachment: MessageAttachment) -> String {
        if let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            return lastPathComponent.isEmpty ? path : lastPathComponent
        }
        return String(localized: "Audio")
    }

    func inlineAudioPlayer(for attachment: MessageAttachment, localData: Data?) -> InlineAudioPlayerView {
        InlineAudioPlayerView(
            title: audioDisplayName(for: attachment),
            load: audioLoader(for: attachment),
            loadKey: attachmentAudio?.loadKey,
            onOpen: attachmentAudio?.openAction(
                for: attachment,
                localData: localData,
                onPreview: onPreviewAttachment.map { preview in { preview(($0, $1), []) } }
            )
        )
    }

    private func audioLoader(for attachment: MessageAttachment) -> () async -> Data? {
        let resolvedPath: String? = {
            if let path = attachment.path, !path.isEmpty { return path }
            if let name = attachment.name, !name.isEmpty { return name }
            return nil
        }()
        let load = attachmentAudio?.load
        return {
            guard let resolvedPath, let load else { return nil }
            return await load(resolvedPath)
        }
    }

    private func rowCount(items: [MessageAttachmentPreview], columns: Int) -> Int {
        (items.count + columns - 1) / columns
    }

    private var attachmentsWithPreviews: [MessageAttachmentPreview] {
        guard let attachments = message.attachments else { return [] }
        return attachments.map { attachment in
            let key = attachment.path ?? attachment.name ?? ""
            let localData = localAttachmentPreviews?[key]
            return (attachment, localData)
        }
    }

    private var isUserMessage: Bool {
        message.role == "user"
    }

    private var isLocalNotice: Bool {
        message.role == "local_notice"
    }

    private var isLocalAssistant: Bool {
        message.role == "local_assistant"
    }

    private var userBubbleLeadingGutter: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 32
    }

    private static let userBubbleHorizontalPadding: CGFloat = 14

    private var userBubbleBodyFont: UIFont {
        .app(forTextStyle: .body, at: dynamicTypeSize)
    }

    private var userBubbleBackground: Color {
        let fill = Color(.appUserBubble)
        return isQueued ? fill.mix(with: Color(.appCanvas), by: 0.45) : fill
    }

    private var userBubbleForeground: Color {
        Color(.appText)
    }

    private var userBubbleBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.04)
    }

    private var messageText: String {
        guard let content = message.content, !content.isEmpty else {
            return " "
        }

        return content
    }

    private var userBubbleText: String {
        let content = message.content ?? ""
        guard !textOnly, hidesAttachmentPaths else { return content }
        return MessageAttachment.contentWithoutAttachedFilesMarker(in: content)
    }
}

private struct UserBubbleFold {
    let text: String
    let rowWidth: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let wrapsPastLimit: Bool

    func folds(_ text: String, at dynamicTypeSize: DynamicTypeSize) -> Bool {
        wrapsPastLimit && dynamicTypeSize == self.dynamicTypeSize && text == self.text
    }
}

private extension [TranscriptMediaSegment] {
    var containsTranscriptMedia: Bool {
        contains { segment in
            if case .media = segment {
                return true
            }
            return false
        }
    }

    var mediaReferences: [TranscriptMediaReference] {
        compactMap { segment in
            if case let .media(reference) = segment {
                return reference
            }
            return nil
        }
    }
}

typealias MessageAttachmentPreview = (attachment: MessageAttachment, localData: Data?)

struct AttachmentAudioSource: Equatable {
    let load: (String) async -> Data?
    let isHost: Bool
    var loadKey: Int? = 0

    static func == (lhs: AttachmentAudioSource, rhs: AttachmentAudioSource) -> Bool {
        lhs.isHost == rhs.isHost && lhs.loadKey == rhs.loadKey
    }

    func playsInline(_ attachment: MessageAttachment) -> Bool {
        guard attachment.inferredIsAudio else { return false }
        return !isHost || attachment.path?.isEmpty == false
    }

    func openAction(
        for attachment: MessageAttachment,
        localData: Data?,
        onPreview: ((MessageAttachment, Data?) -> Void)?
    ) -> (() -> Void)? {
        guard isHost, let onPreview else { return nil }
        return { onPreview(attachment, localData) }
    }
}

private struct GridAttachmentCell: View {
    let attachment: MessageAttachment
    let localData: Data?
    let cacheNamespace: String
    let loadAttachmentImage: ((String) async -> Data?)?
    let onPreviewAttachment: ((MessageAttachment, Data?) -> Void)?
    let size: CGFloat

    private var resolvedPath: String? {
        if let path = attachment.path, !path.isEmpty { return path }
        if let name = attachment.name, !name.isEmpty { return name }
        return nil
    }

    var body: some View {
        if let onPreviewAttachment {
            Button {
                onPreviewAttachment(attachment, localData)
            } label: {
                cellContent
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel("Open attachment \(fileDisplayName)")
        } else {
            cellContent
        }
    }

    @ViewBuilder
    private var cellContent: some View {
        if inferredIsImage {
            imageCell
        } else {
            fileCell
        }
    }

    private var inferredIsImage: Bool {
        if attachment.isImage == true { return true }

        if let mime = attachment.mime?.lowercased(), mime.hasPrefix("image/") { return true }

        let ext = URL(fileURLWithPath: attachment.name ?? resolvedPath ?? "").pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext)
    }

    @ViewBuilder
    private var imageCell: some View {
        ZStack {
            if let localData, let uiImage = UIImage(data: localData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else if let path = resolvedPath, let loadAttachmentImage {
                RemoteAttachmentImage(
                    path: path,
                    cacheNamespace: cacheNamespace,
                    loadAttachmentImage: loadAttachmentImage
                )
                .frame(width: size, height: size)
                .clipped()
            } else {
                fallbackImage
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image attachment \(attachmentAccessibilityName)")
    }

    private var fileCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.appSurface))

            VStack(spacing: 5) {
                Image(systemName: fileIconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(fileBadgeColor)

                Text(fileDisplayName)
                    .font(AppFont.caption2(weight: .medium))
                    .foregroundStyle(Color(.appText))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: size - 18)

                Text(fileExtensionLabel)
                    .font(AppFont.fixed(size: 11, weight: .bold))
                    .foregroundStyle(fileBadgeColor)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File attachment \(fileDisplayName), \(fileExtensionLabel)")
    }

    private var fallbackImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.appFill))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(.appTextTertiary))
            )
    }

    private var fileExtensionLabel: String {
        let ext = URL(fileURLWithPath: attachment.name ?? "").pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE") : String(ext.prefix(5))
    }

    private var fileDisplayName: String {
        if let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        if let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            return lastPathComponent.isEmpty ? path : lastPathComponent
        }

        return String(localized: "File")
    }

    private var attachmentAccessibilityName: String {
        fileDisplayName == String(localized: "File") ? String(localized: "image") : fileDisplayName
    }

    private var fileIconName: String {
        switch URL(fileURLWithPath: attachment.name ?? "").pathExtension.lowercased() {
        case "csv", "tsv", "xls", "xlsx":
            "tablecells"
        case "json", "md", "txt", "log", "xml", "yaml", "yml":
            "doc.text"
        case "pdf":
            "doc.richtext"
        case "zip", "tar", "gz", "tgz":
            "archivebox"
        default:
            "doc"
        }
    }

    private var fileBadgeColor: Color {
        switch URL(fileURLWithPath: attachment.name ?? "").pathExtension.lowercased() {
        case "csv", "tsv", "xls", "xlsx":
            Color.green
        case "pdf":
            Color.red
        case "json", "md", "txt", "log", "xml", "yaml", "yml":
            Color.blue
        default:
            Color.accentColor
        }
    }
}

private struct RemoteAttachmentImage: View {
    let path: String
    let cacheNamespace: String
    let loadAttachmentImage: (String) async -> Data?
    @State private var image: UIImage?
    @State private var didAttempt = false
    @State private var admittedImageKey: AttachmentImageCacheKey?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !didAttempt {
                placeholderImage
            } else {
                fallbackImage
            }
        }
        .loadsOnceVisible(id: imageCacheKey) { admittedImageKey = $0 }
        .task(id: admittedImageKey) {
            guard admittedImageKey == imageCacheKey else { return }
            image = nil
            didAttempt = false
            let path = path
            let loaded = await TranscriptImageCache.shared.image(forKey: imageCacheKey.cacheKey) {
                await loadAttachmentImage(path)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.image = loaded
                self.didAttempt = true
            }
        }
    }

    private var imageCacheKey: AttachmentImageCacheKey {
        AttachmentImageCacheKey(namespace: cacheNamespace, path: path)
    }

    private var fallbackImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.appFill))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color(.appTextTertiary))
            )
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.appFill))
            .overlay(
                ProgressView()
                    .tint(Color(.appTextTertiary))
            )
    }
}

struct AttachmentImageCacheKey: Hashable {
    let namespace: String
    let path: String

    var cacheKey: String {
        "attachment|\(namespace.utf8.count)|\(namespace)|\(path)"
    }
}

enum ResponseSpeedFormatter {
    static func compactText(_ tokensPerSecond: Double?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond > 0 else { return nil }
        let value = tokensPerSecond.formatted(
            .number.locale(locale).precision(.fractionLength(1))
        )
        return "\(value) t/s"
    }

    static func accessibilityText(
        _ tokensPerSecond: Double?,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let compact = compactText(tokensPerSecond, locale: locale) else { return nil }
        let value = compact.dropLast(4)
        return "\(value) \(String(localized: "tokens per second"))"
    }
}

private struct SettledReplyInputs: Hashable {
    let workspaceRoot: String?
    let resolvesBarePaths: Bool
    let cacheNamespace: String
    let loadsMediaImages: Bool
    let loadsMediaData: Bool
    let previewsMedia: Bool
}

@MainActor
private final class SettledReplyMedia {
    private var loadImage: ((TranscriptMediaReference) async -> Data?)?
    private var loadData: ((TranscriptMediaReference) async -> Data?)?
    private var preview: ((TranscriptMediaReference) -> Void)?

    func refreshed(
        loadImage: ((TranscriptMediaReference) async -> Data?)?,
        loadData: ((TranscriptMediaReference) async -> Data?)?,
        preview: ((TranscriptMediaReference) -> Void)?
    ) -> (
        loadImage: ((TranscriptMediaReference) async -> Data?)?,
        loadData: ((TranscriptMediaReference) async -> Data?)?,
        preview: ((TranscriptMediaReference) -> Void)?
    ) {
        self.loadImage = loadImage
        self.loadData = loadData
        self.preview = preview
        return (
            loadImage.map { _ in { @MainActor reference in await self.loadImage?(reference) ?? nil } },
            loadData.map { _ in { @MainActor reference in await self.loadData?(reference) ?? nil } },
            preview.map { _ in { self.preview?($0) } }
        )
    }
}
