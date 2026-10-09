import SwiftUI
import WatchShared

/// Renders the phone's wrist-normalized Markdown. Block structure comes from
/// `WatchTranscriptProjection.wristLines`; inline emphasis, inline code and
/// link labels are styled here with Foundation's own Markdown parser, so the
/// watch needs no Markdown dependency. Used by the transcript and every glance
/// that shows server prose (memory, skills, Cards, task output). Fonts stay
/// semantic for Dynamic Type and nothing here animates.
struct WatchMarkdownText: View {
    let text: String
    var font: Font = .footnote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(WatchTranscriptProjection.wristLines(in: text).enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: WatchTranscriptProjection.WristLine) -> some View {
        switch line {
        case .blank:
            Color.clear.frame(height: 2)
        case .heading(let level, let body):
            Text(Self.inline(body))
                .font(Self.headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .quote(let body):
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.secondary)
                    .frame(width: 2)
                Text(Self.inline(body))
                    .font(font.italic())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let depth, let body):
            marker("•", body: body)
                .padding(.leading, CGFloat(depth) * 8)
        case .ordered(let number, let body):
            marker("\(number).", body: body)
        case .paragraph(let body):
            Text(Self.inline(body))
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func marker(_ glyph: String, body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: glyph)
                .font(font)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.inline(body))
                .font(font)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// System blue is unclaimed by the watch status palette (orange running,
    /// yellow needs you, red record/error, green done) and stays legible on
    /// black at caption sizes.
    private static let linkTint = Color.blue

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        case 3: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }

    /// Server text is never treated as a localization key: it is parsed as
    /// Markdown and handed to `Text` as an `AttributedString`.
    static func inline(_ markdown: String) -> AttributedString {
        var result: AttributedString
        do {
            result = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(WatchTextBreaking.breakable(markdown))
        }
        for range in result.runs.filter({ $0.inlinePresentationIntent?.contains(.code) == true }).map(\.range) {
            result[range].font = .system(.footnote, design: .monospaced)
        }
        // Not `.accentColor`: the watch target ships no AccentColor asset, so
        // it resolves to a gray that reads like disabled text on black.
        for range in result.runs.filter({ $0.link != nil }).map(\.range) {
            result[range].foregroundColor = Self.linkTint
            result[range].underlineStyle = nil
        }
        return breakingLongTokens(result)
    }

    /// Plain prose and link labels get break opportunities inside emails, URLs
    /// and paths. Markdown autolinks an email, so skipping links left
    /// `gmail.-com` on screen. Inline code keeps its text. Hyphenation is off
    /// so a wrap never invents a hyphen.
    private static func breakingLongTokens(_ text: AttributedString) -> AttributedString {
        var output = AttributedString()
        for run in text.runs {
            let piece = AttributedString(text[run.range])
            guard run.inlinePresentationIntent?.contains(.code) != true else {
                output.append(piece)
                continue
            }
            let plain = String(piece.characters)
            let broken = WatchTextBreaking.breakable(plain)
            output.append(broken == plain ? piece : AttributedString(broken, attributes: run.attributes))
        }
        var paragraph = NSMutableParagraphStyle()
        paragraph.hyphenationFactor = 0
        output.paragraphStyle = paragraph
        return output
    }
}
