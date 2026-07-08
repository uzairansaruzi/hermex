import SwiftUI

struct MessageBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTranscriptDisplaySettings.hidesAttachmentPathsKey) private var hidesAttachmentPaths = true
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) private var showsAssistantTurnTimestamps = false

    let message: ChatMessage
    let loadAttachmentImage: ((String) async -> Data?)?
    let loadAttachmentData: ((String) async -> Data?)?
    let loadTranscriptMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadTranscriptMediaData: ((TranscriptMediaReference) async -> Data?)?
    let transcriptMediaCacheNamespace: String
    let localAttachmentPreviews: [String: Data]?
    let onPreviewAttachment: ((MessageAttachment, Data?) -> Void)?
    let onPreviewTranscriptMedia: ((TranscriptMediaReference) -> Void)?
    let isStreaming: Bool

    init(
        message: ChatMessage,
        loadAttachmentImage: ((String) async -> Data?)? = nil,
        loadAttachmentData: ((String) async -> Data?)? = nil,
        loadTranscriptMediaImage: ((TranscriptMediaReference) async -> Data?)? = nil,
        loadTranscriptMediaData: ((TranscriptMediaReference) async -> Data?)? = nil,
        transcriptMediaCacheNamespace: String = "",
        localAttachmentPreviews: [String: Data]? = nil,
        onPreviewAttachment: ((MessageAttachment, Data?) -> Void)? = nil,
        onPreviewTranscriptMedia: ((TranscriptMediaReference) -> Void)? = nil,
        isStreaming: Bool = false
    ) {
        self.message = message
        self.loadAttachmentImage = loadAttachmentImage
        self.loadAttachmentData = loadAttachmentData
        self.loadTranscriptMediaImage = loadTranscriptMediaImage
        self.loadTranscriptMediaData = loadTranscriptMediaData
        self.transcriptMediaCacheNamespace = transcriptMediaCacheNamespace
        self.localAttachmentPreviews = localAttachmentPreviews
        self.onPreviewAttachment = onPreviewAttachment
        self.onPreviewTranscriptMedia = onPreviewTranscriptMedia
        self.isStreaming = isStreaming
    }

    var body: some View {
        if isLocalNotice {
            localNoticeRow
        } else if isLocalAssistant {
            localAssistantRow
        } else if isUserMessage {
            userMessageRow
        } else {
            assistantMessageRow
        }
    }

    private var userMessageRow: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let attachments = message.attachments, !attachments.isEmpty {
                attachmentPreviews
            }

            // When the attachment-path line is hidden, an attachment-only
            // message has no bubble text left; skip the empty pill so only the
            // attachment grid shows.
            if hasVisibleUserBubbleText || hasLinkPreview {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: userBubbleLeadingGutter)
                    VStack(alignment: .trailing, spacing: 8) {
                        if hasVisibleUserBubbleText {
                            userBubble
                        }
                        linkPreview
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 2)
    }

    private var assistantMessageRow: some View {
        let segments = TranscriptMediaParser.segments(in: messageText)

        return VStack(alignment: .leading, spacing: 6) {
            if showsAssistantTurnHeaderForThisMessage {
                assistantTurnHeader
            }

            if segments.containsTranscriptMedia {
                TranscriptMediaContentView(
                    segments: segments,
                    cacheNamespace: transcriptMediaCacheNamespace,
                    loadMediaImage: loadTranscriptMediaImage,
                    loadMediaData: loadTranscriptMediaData,
                    onPreviewMedia: onPreviewTranscriptMedia,
                    isStreaming: isStreaming
                )
            } else {
                MarkdownRenderer(content: messageText, isStreaming: isStreaming)
            }

            linkPreview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        // While this row is the active streaming message, animate its height
        // growth at the same curve as the bottom-follow scroll so the streaming
        // edge stays visually stationary instead of stepping per word flush.
        .animation(
            isStreaming ? ChatMotion.streamingFollow(reduceMotion: reduceMotion) : nil,
            value: messageText
        )
    }

    // MARK: - Assistant turn header (issue #258)

    /// A compact, generic `glyph + time` marker drawn above each assistant text
    /// turn so back-to-back responses are visually separable. Deliberately carries
    /// no model/profile/agent identity — only the message's own timestamp, which
    /// is the single per-message-accurate datum available.
    private var assistantTurnHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            if let time = assistantTurnTimeText {
                Text(time)
                    .foregroundStyle(.secondary)
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
            isEnabled: showsAssistantTurnTimestamps
        )
    }

    /// Uses the raw `content` (not `messageText`, which substitutes a placeholder
    /// space) so an empty or tool-call-only assistant row never shows a floating
    /// header.
    private var hasVisibleAssistantText: Bool {
        guard let content = message.content else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var assistantTurnTimeText: String? {
        AssistantTurnTimestampFormatter.shortTime(forUnixTimestamp: message.timestamp)
    }

    private var assistantTurnHeaderAccessibilityLabel: String {
        guard let time = assistantTurnTimeText else { return String(localized: "Assistant") }
        return String(localized: "Assistant, \(time)")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }

    private var userBubble: some View {
        Text(verbatim: userBubbleText)
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(userBubbleBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(userBubbleForeground)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(userBubbleBorder, lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var linkPreview: some View {
        if let url = TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: isStreaming) {
            TranscriptLinkPreviewView(url: url)
                .frame(maxWidth: 300)
        }
    }

    private var hasLinkPreview: Bool {
        TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: isStreaming) != nil
    }

    // Audio attachments render as full-width Telegram-style player bars stacked
    // above the square image/file grid; everything else stays in the grid.
    private var attachmentPreviews: some View {
        let allItems = attachmentsWithPreviews
        let audioItems = allItems.filter { $0.attachment.inferredIsAudio }
        let gridItems = allItems.filter { !$0.attachment.inferredIsAudio }
        let columns = 2
        let spacing: CGFloat = 8
        let cellSize: CGFloat = 118
        let contentWidth = CGFloat(columns) * cellSize + CGFloat(columns - 1) * spacing

        return VStack(alignment: .trailing, spacing: spacing) {
            ForEach(audioItems.indices, id: \.self) { index in
                let attachment = audioItems[index].attachment
                InlineAudioPlayerView(
                    title: audioDisplayName(for: attachment),
                    load: audioLoader(for: attachment)
                )
                // Identity follows the attachment, not the row position. The
                // transcript bubble's id is positional (`transcript:<index>`),
                // so without this a recycled row would keep its old `@State`
                // model (and stale audio bytes) for a different clip.
                .id(attachment.path ?? attachment.name ?? "\(index)")
                .frame(width: contentWidth, alignment: .trailing)
            }

            if !gridItems.isEmpty {
                attachmentGrid(
                    items: gridItems,
                    columns: columns,
                    cellSize: cellSize,
                    spacing: spacing,
                    width: contentWidth
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func attachmentGrid(
        items: [(attachment: MessageAttachment, localData: Data?)],
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
                            loadAttachmentImage: loadAttachmentImage,
                            onPreviewAttachment: onPreviewAttachment,
                            size: cellSize
                        )
                        .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    /// Display name for an audio bar, mirroring the grid file cell's logic.
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

    /// Builds the lazy byte loader for an audio bar. Resolves the server path
    /// (or filename fallback) once and defers to the injected raw-data loader.
    private func audioLoader(for attachment: MessageAttachment) -> () async -> Data? {
        let resolvedPath: String? = {
            if let path = attachment.path, !path.isEmpty { return path }
            if let name = attachment.name, !name.isEmpty { return name }
            return nil
        }()
        let loadAttachmentData = loadAttachmentData
        return {
            guard let resolvedPath, let loadAttachmentData else { return nil }
            return await loadAttachmentData(resolvedPath)
        }
    }

    private func rowCount(items: [(attachment: MessageAttachment, localData: Data?)], columns: Int) -> Int {
        (items.count + columns - 1) / columns
    }

    private var attachmentsWithPreviews: [(attachment: MessageAttachment, localData: Data?)] {
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

    private var userBubbleBackground: Color {
        colorScheme == .dark ? Color(.systemGray3) : Color(.systemGray6)
    }

    private var userBubbleForeground: Color {
        Color(.label)
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

    /// The user bubble's text, with the appended attachment-path marker stripped
    /// when the user has opted to hide it. Display-only: `message.content` and the
    /// sent payload are untouched.
    private var userBubbleText: String {
        let content = message.content ?? ""
        guard hidesAttachmentPaths else { return content }
        return MessageAttachment.contentWithoutAttachedFilesMarker(in: content)
    }

    private var hasVisibleUserBubbleText: Bool {
        !userBubbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
}

private struct GridAttachmentCell: View {
    let attachment: MessageAttachment
    let localData: Data?
    let loadAttachmentImage: ((String) async -> Data?)?
    let onPreviewAttachment: ((MessageAttachment, Data?) -> Void)?
    let size: CGFloat

    private var resolvedPath: String? {
        // The server saves uploads to the workspace root. Use the explicit
        // path when available; for older sessions fall back to filename.
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
        // Explicit server flag is the strongest signal.
        if attachment.isImage == true { return true }

        // Fall back to MIME type (e.g. "image/jpeg").
        if let mime = attachment.mime?.lowercased(), mime.hasPrefix("image/") { return true }

        // Fall back to file extension for older sessions where the server
        // did not persist `is_image`.
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
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image attachment \(attachmentAccessibilityName)")
    }

    private var fileCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            VStack(spacing: 5) {
                Image(systemName: fileIconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(fileBadgeColor)

                Text(fileDisplayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: size - 18)

                Text(fileExtensionLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(fileBadgeColor)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File attachment \(fileDisplayName), \(fileExtensionLabel)")
    }

    private var fallbackImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(.tertiaryLabel))
            )
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                ProgressView()
                    .tint(Color(.tertiaryLabel))
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

// MARK: - Remote image loading with cookie-aware session

/// Loads attachment images through the authenticated `APIClient` instead of
/// `AsyncImage`, which uses `URLSession.shared` and may not carry our auth
/// cookie. Deduplicates concurrent requests and caches in memory.
private struct RemoteAttachmentImage: View {
    let path: String
    let loadAttachmentImage: (String) async -> Data?
    @State private var image: UIImage?
    @State private var didAttempt = false

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
        .task(id: path) {
            let loaded = await AttachmentImageCache.shared.image(
                for: path,
                loadAttachmentImage: loadAttachmentImage
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.image = loaded
                self.didAttempt = true
            }
        }
    }

    private var fallbackImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color(.tertiaryLabel))
            )
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.systemFill))
            .overlay(
                ProgressView()
                    .tint(Color(.tertiaryLabel))
            )
    }
}

/// In-memory image cache that delegates loading to the authenticated client.
/// Deduplicates concurrent requests for the same path.
private actor AttachmentImageCache {
    static let shared = AttachmentImageCache()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(
        for path: String,
        loadAttachmentImage: @escaping (String) async -> Data?
    ) async -> UIImage? {
        if let cached = cache[path] {
            return cached
        }

        if let task = inFlight[path] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await loadAttachmentImage(path) else {
                return nil
            }
            let previewData = ImagePreviewDownsampler.previewData(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            ) ?? data
            return UIImage(data: previewData)
        }

        inFlight[path] = task
        let image = await task.value
        inFlight[path] = nil

        if let image {
            cache[path] = image
        }
        return image
    }
}

// MARK: - Assistant turn timestamp formatting

/// Formats an assistant turn's unix `timestamp` as a short, locale-/24h-aware
/// time (e.g. `2:14 PM` or `14:14`). Returns `nil` for a missing or non-finite
/// timestamp so the per-turn header falls back to glyph-only.
enum AssistantTurnTimestampFormatter {
    private static let sharedFormatter: DateFormatter = makeFormatter(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    static func shortTime(forUnixTimestamp timestamp: Double?) -> String? {
        format(timestamp, with: sharedFormatter)
    }

    /// Test seam: format against an explicit locale/time zone so 12h/24h
    /// assertions stay deterministic regardless of host device settings.
    static func shortTime(
        forUnixTimestamp timestamp: Double?,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        format(timestamp, with: makeFormatter(locale: locale, timeZone: timeZone))
    }

    private static func makeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static func format(_ timestamp: Double?, with formatter: DateFormatter) -> String? {
        guard let timestamp, timestamp.isFinite else { return nil }
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
