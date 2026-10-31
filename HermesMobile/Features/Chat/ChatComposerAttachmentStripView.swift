import SwiftUI
import UIKit

/// A staged document's badge slot in the strip. Its Quick Look preview is made
/// at this size, and the pill's smaller tile draws the same image scaled down.
private let documentBadgeSize = CGSize(width: 58, height: 68)

struct ComposerAttachmentStripView: View {
    let attachments: [PendingAttachment]
    /// Per-file upload phases (#1419): a static glyph on each tile, no progress.
    var marks: [UUID: HermesChatTurnCoordinator.AttachmentTransfer.Mark] = [:]
    let onRemove: (UUID) -> Void
    let onPreview: (PendingAttachment) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentThumbnailView(
                            attachment: attachment,
                            mark: marks[attachment.id],
                            onRemove: { onRemove(attachment.id) },
                            onOpen: { onPreview(attachment) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .frame(height: stripHeight)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private var stripHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 132 : 108
    }
}

/// A transfer mark's tile glyph color and VoiceOver phrase (#1419).
extension HermesChatTurnCoordinator.AttachmentTransfer.Mark {
    var tint: Color {
        switch self {
        case .waiting, .preparing: return Color(.secondaryLabel)
        case .uploading: return Color.accentColor
        case .done: return Color.green
        case .failed: return Color.red
        }
    }

    /// Nil for `.waiting`: an unreached file needs no phase announced.
    func accessibilityPhrase(filename: String) -> String? {
        switch self {
        case .waiting: return nil
        case .preparing, .uploading: return String(localized: "Uploading \(filename)")
        case .done: return String(localized: "Uploaded \(filename)")
        case .failed: return String(localized: "Failed to upload \(filename)")
        }
    }
}

/// Pill-state summary of pending attachments: up to three 30 pt tiles plus a
/// `+N` chip, so nothing pending is ever out of sight while the editor is idle.
struct ComposerAttachmentPillPreview: View {
    let attachments: [PendingAttachment]
    /// Per-file upload phases (#1419): marks show on visible tiles, and a mark on a
    /// file past the visible ones surfaces on the `+N` chip so nothing is out of sight.
    var marks: [UUID: HermesChatTurnCoordinator.AttachmentTransfer.Mark] = [:]
    let onPreview: (PendingAttachment) -> Void

    private let tileSize: CGFloat = 30
    private let visibleLimit = 3

    var body: some View {
        if !attachments.isEmpty {
            HStack(spacing: 4) {
                ForEach(attachments.prefix(visibleLimit)) { attachment in
                    Button {
                        onPreview(attachment)
                    } label: {
                        tile(for: attachment)
                    }
                    .buttonStyle(.chatTactile(.thumbnail))
                    .accessibilityLabel(accessibilityLabel(for: attachment))
                }

                if attachments.count > visibleLimit {
                    let hiddenCount = attachments.count - visibleLimit
                    Text("+\(hiddenCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: tileSize, height: tileSize)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if let hidden = hiddenMarkedFile {
                                Image(systemName: hidden.mark.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(hidden.mark.tint)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(Color(.systemBackground).opacity(0.85)))
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .accessibilityLabel(hiddenAccessibilityLabel(hiddenCount: hiddenCount))
                }
            }
        }
    }

    /// A mark on a file past the visible tiles: its failure first, else the upload in
    /// flight, so the collapsed pill still identifies it (#1419).
    private var hiddenMarkedFile: (name: String, mark: HermesChatTurnCoordinator.AttachmentTransfer.Mark)? {
        let order: [HermesChatTurnCoordinator.AttachmentTransfer.Mark] = [.failed, .uploading, .preparing, .done]
        for mark in order {
            if let attachment = attachments.dropFirst(visibleLimit).first(where: { marks[$0.id] == mark }) {
                return (attachment.name, mark)
            }
        }
        return nil
    }

    private func accessibilityLabel(for attachment: PendingAttachment) -> Text {
        let base = Text("Open attachment \(attachment.name)")
        guard let mark = marks[attachment.id], let phrase = mark.accessibilityPhrase(filename: attachment.name) else {
            return base
        }
        return base + Text(", ") + Text(verbatim: phrase)
    }

    private func hiddenAccessibilityLabel(hiddenCount: Int) -> Text {
        let more = Text("\(hiddenCount) more attachments")
        guard let hidden = hiddenMarkedFile, let phrase = hidden.mark.accessibilityPhrase(filename: hidden.name) else {
            return more
        }
        return Text(verbatim: phrase) + Text(", ") + more
    }

    @ViewBuilder
    private func tile(for attachment: PendingAttachment) -> some View {
        Group {
            if attachment.isImage,
               let thumbnailData = attachment.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if attachment.isImage {
                placeholderTile(systemName: "photo")
            } else {
                ComposerDocumentThumbnail(attachment: attachment) { thumbnail in
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholderTile(systemName: "doc")
                    }
                }
            }
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let mark = marks[attachment.id], mark != .waiting {
                Image(systemName: mark.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mark.tint)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color(.systemBackground).opacity(0.85)))
                    .offset(x: 4, y: 4)
            }
        }
    }

    private func placeholderTile(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(.secondaryLabel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.tertiarySystemFill))
    }
}

/// Loads a staged document's Quick Look preview and hands it to `content`:
/// nil until it arrives, and for good when Quick Look can't draw one, so the
/// tile keeps its icon. A preview made earlier, by this tile or the other
/// composer state, draws in the first frame. The swap never animates.
private struct ComposerDocumentThumbnail<Content: View>: View {
    let attachment: PendingAttachment
    @ViewBuilder let content: (UIImage?) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?

    var body: some View {
        content(loaded ?? ComposerDocumentThumbnails.shared.cachedThumbnail(for: attachment.id))
            .task(id: attachment.id) {
                let image = await ComposerDocumentThumbnails.shared.thumbnail(
                    for: attachment,
                    size: documentBadgeSize,
                    scale: displayScale
                )
                guard !Task.isCancelled, image !== loaded else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { loaded = image }
            }
    }
}

private struct ComposerAttachmentThumbnailView: View {
    let attachment: PendingAttachment
    /// The file's upload phase (#1419): a static corner glyph, and the phase in the
    /// tile's VoiceOver labels.
    let mark: HermesChatTurnCoordinator.AttachmentTransfer.Mark?
    let onRemove: () -> Void
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                thumbnailContent
                    .overlay(alignment: .topLeading) { transferMarkBadge }
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(openAccessibilityLabel)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(.systemBackground)))
                    .foregroundStyle(Color(.label))
                    .overlay(Circle().stroke(Color(.separator).opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.chatTactile(
                .icon,
                shadow: ChatTactileButtonStyle.Shadow(
                    color: .black,
                    opacity: 0.12,
                    radius: 3,
                    y: 1,
                    pressedOpacity: 0.06,
                    pressedRadius: 1,
                    pressedY: 0
                )
            ))
            .offset(x: RTLLayout.horizontalOffset(6, isRightToLeft: layoutDirection == .rightToLeft), y: -6)
            .accessibilityLabel("Remove attachment \(attachment.name)")
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if attachment.isImage {
            imagePreview
        } else {
            filePreview
        }
    }

    /// The upload phase as a static corner glyph; nothing while waiting or idle (#1419).
    @ViewBuilder
    private var transferMarkBadge: some View {
        if let mark = mark, mark != .waiting {
            Image(systemName: mark.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mark.tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(.systemBackground).opacity(0.85)))
                .overlay(Circle().stroke(Color(.separator).opacity(0.35), lineWidth: 0.5))
                .offset(x: 4, y: 4)
                .accessibilityHidden(true)
        }
    }

    private var openAccessibilityLabel: Text {
        labeled(Text("Open attachment \(attachment.name)"))
    }

    /// The tile's label with the file's upload phase appended, when it has one (#1419).
    private func labeled(_ base: Text) -> Text {
        guard let mark = mark, let phrase = mark.accessibilityPhrase(filename: attachment.name) else { return base }
        return base + Text(", ") + Text(verbatim: phrase)
    }

    @ViewBuilder
    private var imagePreview: some View {
        Group {
            if let thumbnailData = attachment.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemFill))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(Color(.tertiaryLabel))
                    )
            }
        }
        .frame(width: imagePreviewSize, height: imagePreviewSize)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(previewBorder(cornerRadius: 14))
        .accessibilityLabel(labeled(Text("Image attachment \(attachment.name)")))
    }

    private var filePreview: some View {
        HStack(alignment: .center, spacing: 12) {
            ComposerDocumentThumbnail(attachment: attachment) { thumbnail in
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: documentBadgeSize.width, height: documentBadgeSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        // Keeps a white page from dissolving into a light
                        // tile, and gives it an edge in dark mode.
                        .overlay(previewBorder(cornerRadius: 10))
                } else {
                    fileBadge
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(attachment.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(fileDetailText)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(usesAccessibilityLayout ? 2 : 1)
            }
            .frame(width: usesAccessibilityLayout ? 160 : 128, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, usesAccessibilityLayout ? 10 : 0)
        .frame(width: usesAccessibilityLayout ? 260 : 222)
        .frame(minHeight: usesAccessibilityLayout ? 112 : 92)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(previewBorder(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labeled(Text("File attachment \(attachment.name), \(fileDetailText)")))
    }

    /// The document's icon and extension, until (or unless) Quick Look draws
    /// a preview in the same slot.
    private var fileBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fileBadgeColor.opacity(0.15))

            VStack(spacing: 3) {
                Image(systemName: fileIconName)
                    .font(.system(size: 24, weight: .semibold))
                Text(fileExtensionLabel)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(fileBadgeColor)
        }
        .frame(width: documentBadgeSize.width, height: documentBadgeSize.height)
    }

    private func previewBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
    }

    private var fileExtensionLabel: String {
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE") : String(ext.prefix(5))
    }

    private var fileIconName: String {
        switch URL(fileURLWithPath: attachment.name).pathExtension.lowercased() {
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
        switch URL(fileURLWithPath: attachment.name).pathExtension.lowercased() {
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

    private var fileDetailText: String {
        if let size = attachment.size {
            ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            fileExtensionLabel
        }
    }

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var imagePreviewSize: CGFloat {
        usesAccessibilityLayout ? 108 : 96
    }
}
