import SwiftUI
import UIKit

struct ComposerAttachmentStripView: View {
    let attachments: [PendingAttachment]
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
        }
    }

    private var stripHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 132 : 108
    }
}

private struct ComposerAttachmentThumbnailView: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                thumbnailContent
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel("Open attachment \(attachment.name)")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ChatPalette.appChrome(colorScheme: colorScheme).chatBackground))
                    .foregroundStyle(Color(.label))
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

    @ViewBuilder
    private var imagePreview: some View {
        Group {
            if let thumbnailData = attachment.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .accessibilityLabel("Image attachment \(attachment.name)")
    }

    private var filePreview: some View {
        HStack(alignment: .center, spacing: 12) {
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
            .frame(width: 58, height: 68)

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
                .fill(ChatPalette.appChrome(colorScheme: colorScheme).surface)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File attachment \(attachment.name), \(fileDetailText)")
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
