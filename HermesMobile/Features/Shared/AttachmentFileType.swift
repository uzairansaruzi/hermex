import SwiftUI

/// Maps an attachment's file name to the icon, tint, and extension label its tile shows — shared by
/// a sent message's file cell (`MessageBubbleView`) and the composer's pending-attachment preview
/// (`ChatComposerAttachmentStripView`), which independently implemented the exact same switch.
struct AttachmentFileType {
    let iconName: String
    let tintColor: Color
    let extensionLabel: String

    init(fileName: String) {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()

        switch ext {
        case "csv", "tsv", "xls", "xlsx":
            iconName = "tablecells"
            tintColor = HermesColorRamp.Green.s500.color
        case "json", "md", "txt", "log", "xml", "yaml", "yml":
            iconName = "doc.text"
            tintColor = HermesColorRamp.Blue.s500.color
        case "pdf":
            iconName = "doc.richtext"
            tintColor = HermesColorRamp.Red.s500.color
        case "zip", "tar", "gz", "tgz":
            iconName = "archivebox"
            tintColor = HermesColorRamp.Orange.s500.color
        default:
            iconName = "doc"
            tintColor = HermesColorRamp.Neutral.s500.color
        }

        let uppercased = ext.uppercased()
        extensionLabel = uppercased.isEmpty ? String(localized: "FILE") : String(uppercased.prefix(5))
    }

    /// The one derivation point for a file type's subtle badge fill, so a caller that wants a
    /// tinted panel behind its icon (`AttachmentFileBadge`) never hand-computes its own opacity.
    var badgeFill: Color {
        tintColor.opacity(0.15)
    }
}
