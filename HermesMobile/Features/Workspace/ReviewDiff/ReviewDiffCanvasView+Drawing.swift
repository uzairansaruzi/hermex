import UIKit

/// Drawing for `ReviewDiffCanvasView`. Everything is CoreGraphics on the character
/// grid of the resolved monospaced font: row backgrounds, the solid add bar and striped
/// delete bar, word-diff highlights, the selection overlay, and the file header card.
extension ReviewDiffCanvasView {
    struct FileHeaderInteractiveRects {
        let chevron: CGRect
        let icon: CGRect
        let checkbox: CGRect
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let signpost = reviewDiffSignposter.beginInterval("Draw")
        defer { reviewDiffSignposter.endInterval("Draw", signpost) }

        theme.background.setFill()
        context.fill(rect)
        guard !rows.isEmpty else { return }

        let visibleMinY = verticalOffset + rect.minY
        let visibleMaxY = verticalOffset + rect.maxY
        let overscan = max(style.metrics.rowHeight, style.metrics.fileHeaderHeight) * 4
        guard let range = layout.rowRange(intersecting: max(0, visibleMinY - overscan), visibleMaxY + overscan) else {
            return
        }

        for rowIndex in range {
            guard let frame = frame(forRowAt: rowIndex), frame.height > 0 else { continue }
            let rowStart = frame.minY + verticalOffset
            if rowStart + frame.height < visibleMinY || rowStart > visibleMaxY { continue }
            drawRow(rows[rowIndex], rect: frame, context: context)
        }

        if let sticky = stickyHeaderTarget() {
            drawFileRow(rows[sticky.rowIndex], rect: sticky.rect, context: context)
        }
    }

    private func drawRow(_ row: ReviewDiffRow, rect: CGRect, context: CGContext) {
        switch row.kind {
        case .file:
            drawFileRow(row, rect: rect, context: context)
        case .hunk(let text):
            drawHunkRow(text, fileID: row.fileID, rect: rect, context: context)
        case .notice(let text):
            drawNoticeRow(text, rect: rect, context: context)
        case .line(let line):
            drawCodeRow(row, line: line, rect: rect, context: context)
        }
    }

    // MARK: - File header

    func fileHeaderInteractiveRects(cardRect: CGRect) -> FileHeaderInteractiveRects {
        let centerY = cardRect.midY
        let padding = style.fileHeaderHorizontalPadding
        let chevron = CGRect(x: cardRect.minX + padding, y: centerY - 10, width: 20, height: 20)
        let icon = CGRect(x: chevron.maxX + 8, y: centerY - 10, width: 20, height: 20)
        // The checkbox hit target is generous; the drawn box is inset from it.
        let checkbox = CGRect(x: cardRect.maxX - padding - 32, y: centerY - 22, width: 44, height: 44)
        return FileHeaderInteractiveRects(chevron: chevron, icon: icon, checkbox: checkbox)
    }

    private func countsText(for header: ReviewDiffFileHeader) -> (add: String, delete: String) {
        ("+\(header.additions)", "−\(header.deletions)")
    }

    func fileHeaderPathRect(for header: ReviewDiffFileHeader, cardRect: CGRect) -> CGRect {
        let rects = fileHeaderInteractiveRects(cardRect: cardRect)
        let counts = countsText(for: header)
        let countsWidth = textWidth(counts.add, font: style.fileHeaderMetaFont)
            + 4 + textWidth(counts.delete, font: style.fileHeaderMetaFont)
        let countsX = checkboxDrawRect(in: rects.checkbox).minX - 10 - countsWidth
        let pathX = rects.icon.maxX + 10
        let height = ceil(style.fileHeaderFont.lineHeight) + 2
        return CGRect(x: pathX, y: cardRect.midY - height / 2, width: max(24, countsX - pathX - 12), height: height)
    }

    private func checkboxDrawRect(in hitRect: CGRect) -> CGRect {
        CGRect(x: hitRect.midX - 10, y: hitRect.midY - 10, width: 20, height: 20)
    }

    func drawFileRow(_ row: ReviewDiffRow, rect: CGRect, context: CGContext) {
        guard let header = row.fileHeader else { return }
        theme.headerBackground.setFill()
        context.fill(rect)

        let hairline = 1 / max(traitCollection.displayScale, 1)
        theme.border.setFill()
        context.fill(CGRect(x: rect.minX, y: rect.maxY - hairline, width: rect.width, height: hairline))

        let rects = fileHeaderInteractiveRects(cardRect: rect)
        let isCollapsed = collapsedFileIDs.contains(row.fileID)
        drawDisclosureChevron(rect: rects.chevron, color: theme.mutedText, collapsed: isCollapsed, context: context)
        drawFileIcon(rect: rects.icon, changeKind: header.changeKind, context: context)
        drawViewedCheckbox(rect: checkboxDrawRect(in: rects.checkbox), checked: viewedFileIDs.contains(row.fileID), context: context)

        let counts = countsText(for: header)
        let addWidth = textWidth(counts.add, font: style.fileHeaderMetaFont)
        let deleteWidth = textWidth(counts.delete, font: style.fileHeaderMetaFont)
        let countsX = checkboxDrawRect(in: rects.checkbox).minX - 10 - (addWidth + 4 + deleteWidth)
        let metaHeight = ceil(style.fileHeaderMetaFont.lineHeight)
        drawSingleLineText(
            counts.add,
            rect: CGRect(x: countsX, y: rect.midY - metaHeight / 2, width: addWidth, height: metaHeight),
            color: theme.addTint,
            font: style.fileHeaderMetaFont,
            context: context
        )
        drawSingleLineText(
            counts.delete,
            rect: CGRect(x: countsX + addWidth + 4, y: rect.midY - metaHeight / 2, width: deleteWidth, height: metaHeight),
            color: theme.deleteTint,
            font: style.fileHeaderMetaFont,
            context: context
        )

        let pathRect = fileHeaderPathRect(for: header, cardRect: rect)
        let pathOffset = horizontalOffset(for: row.fileID, kind: .fileHeaderPath)
        drawSingleLineText(
            header.displayPath,
            rect: pathRect,
            color: theme.text,
            font: style.fileHeaderFont,
            horizontalOffset: pathOffset,
            context: context
        )
        drawPathScrollFade(header, pathRect: pathRect, horizontalOffset: pathOffset, context: context)
    }

    private func drawPathScrollFade(
        _ header: ReviewDiffFileHeader,
        pathRect: CGRect,
        horizontalOffset: CGFloat,
        context: CGContext
    ) {
        let maxOffset = maxHeaderPathOffset(for: header)
        guard maxOffset > 0, pathRect.width > 0 else { return }
        let fadeWidth = min(28, pathRect.width / 3)
        if horizontalOffset > 0.5 {
            drawHorizontalFade(
                rect: CGRect(x: pathRect.minX, y: pathRect.minY, width: fadeWidth, height: pathRect.height),
                fadesToRight: false,
                context: context
            )
        }
        if horizontalOffset < maxOffset - 0.5 {
            drawHorizontalFade(
                rect: CGRect(x: pathRect.maxX - fadeWidth, y: pathRect.minY, width: fadeWidth, height: pathRect.height),
                fadesToRight: true,
                context: context
            )
        }
    }

    private func drawHorizontalFade(rect: CGRect, fadesToRight: Bool, context: CGContext) {
        let color = theme.headerBackground.resolvedColor(with: traitCollection)
        guard rect.width > 0,
              let gradient = CGGradient(
                  colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: [
                      color.withAlphaComponent(fadesToRight ? 0 : 1).cgColor,
                      color.withAlphaComponent(fadesToRight ? 1 : 0).cgColor
                  ] as CFArray,
                  locations: [0, 1]
              ) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.midY),
            end: CGPoint(x: rect.maxX, y: rect.midY),
            options: []
        )
        context.restoreGState()
    }

    // MARK: - Hunk, notice, code rows

    private func drawHunkRow(_ text: String, fileID: String, rect: CGRect, context: CGContext) {
        theme.hunkBackground.setFill()
        context.fill(rect)
        context.saveGState()
        context.clip(to: CGRect(x: style.stickyWidth, y: rect.minY, width: max(0, viewportWidth - style.stickyWidth), height: rect.height))
        drawText(
            text,
            at: CGPoint(x: style.codeStartX - horizontalOffset(for: fileID), y: rect.midY - style.hunkFont.lineHeight / 2),
            color: theme.accent,
            font: style.hunkFont
        )
        context.restoreGState()
    }

    private func drawNoticeRow(_ text: String, rect: CGRect, context: CGContext) {
        theme.background.setFill()
        context.fill(rect)
        let hairline = 1 / max(traitCollection.displayScale, 1)
        theme.border.withAlphaComponent(0.65).setFill()
        context.fill(CGRect(x: 0, y: rect.maxY - hairline, width: rect.width, height: hairline))

        let iconSize: CGFloat = 16
        let iconRect = CGRect(x: style.fileHeaderHorizontalPadding + 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
        drawNoticeIcon(rect: iconRect, color: theme.mutedText, context: context)
        let textHeight = ceil(style.noticeFont.lineHeight)
        drawSingleLineText(
            text,
            rect: CGRect(
                x: iconRect.maxX + 10,
                y: rect.midY - textHeight / 2,
                width: max(24, viewportWidth - iconRect.maxX - 10 - style.fileHeaderHorizontalPadding),
                height: textHeight
            ),
            color: theme.mutedText,
            font: style.noticeFont,
            context: context
        )
    }

    private func drawCodeRow(_ row: ReviewDiffRow, line: ReviewDiffLine, rect: CGRect, context: CGContext) {
        let horizontalOffset = horizontalOffset(for: row.fileID)
        rowBackground(for: line.change).setFill()
        context.fill(rect)

        let barRect = CGRect(x: 0, y: rect.minY, width: style.changeBarWidth, height: rect.height)
        switch line.change {
        case .addition:
            theme.addTint.setFill()
            context.fill(barRect)
        case .deletion:
            drawDeleteStripes(rect: barRect, context: context)
        case .context:
            break
        }

        if selectedRowIDs.contains(row.id) {
            theme.accent.withAlphaComponent(0.22).setFill()
            context.fill(rect)
            theme.accent.withAlphaComponent(0.95).setFill()
            context.fill(barRect)
        }

        if let number = line.displayLineNumber {
            drawRightAlignedText(
                "\(number)",
                rect: CGRect(
                    x: style.changeBarWidth,
                    y: rect.midY - style.lineNumberFont.lineHeight / 2,
                    width: style.gutterWidth - style.codePadding,
                    height: style.lineNumberFont.lineHeight
                ),
                color: lineNumberColor(for: line.change),
                font: style.lineNumberFont
            )
        }

        context.saveGState()
        context.clip(to: CGRect(x: style.stickyWidth, y: rect.minY, width: max(0, viewportWidth - style.stickyWidth), height: rect.height))
        drawWordDiffRanges(line, rowRect: rect, horizontalOffset: horizontalOffset)
        drawCodeText(
            line.content,
            runs: tokensByRowID[row.id] ?? [],
            origin: CGPoint(x: style.codeStartX - horizontalOffset, y: rect.minY + (style.metrics.rowHeight - style.codeFont.lineHeight) / 2),
            color: line.change == .context ? theme.text.withAlphaComponent(0.85) : theme.text
        )
        context.restoreGState()
    }

    /// Code text with optional syntax colour runs, split into visual lines of
    /// `wrapColumns` characters when the layout wraps. The plain, unwrapped case stays
    /// a single string draw so diff rows cost what they did before.
    private func drawCodeText(_ text: String, runs: [SourceHighlightRun], origin: CGPoint, color: UIColor) {
        let wrapColumns = layout.wrapColumns
        if runs.isEmpty, wrapColumns == nil || text.count <= wrapColumns! {
            drawText(text, at: origin, color: color, font: style.codeFont)
            return
        }

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: style.codeFont, .foregroundColor: color, .ligature: 0]
        )
        let bounds = NSRange(location: 0, length: attributed.length)
        for run in runs {
            let clamped = NSIntersectionRange(run.range, bounds)
            guard clamped.length > 0 else { continue }
            attributed.addAttribute(.foregroundColor, value: run.color, range: clamped)
        }

        guard let wrapColumns, text.count > wrapColumns else {
            attributed.draw(at: origin)
            return
        }
        var y = origin.y
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: wrapColumns, limitedBy: text.endIndex) ?? text.endIndex
            attributed.attributedSubstring(from: NSRange(start..<end, in: text)).draw(at: CGPoint(x: origin.x, y: y))
            y += style.metrics.wrappedLineHeight
            start = end
        }
    }

    private func drawWordDiffRanges(_ line: ReviewDiffLine, rowRect: CGRect, horizontalOffset: CGFloat) {
        guard !line.wordDiffRanges.isEmpty else { return }
        let fill: UIColor
        switch line.change {
        case .addition: fill = theme.addTint.withAlphaComponent(0.28)
        case .deletion: fill = theme.deleteTint.withAlphaComponent(0.28)
        case .context: return
        }
        let height = max(4, min(rowRect.height - 4, style.codeFont.lineHeight))
        let y = rowRect.midY - height / 2
        fill.setFill()
        for range in line.wordDiffRanges where !range.isEmpty {
            let x = style.codeStartX - horizontalOffset + CGFloat(range.lowerBound) * style.codeCharacterWidth
            let width = max(2, CGFloat(range.count) * style.codeCharacterWidth)
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: 3).fill()
        }
    }

    private func rowBackground(for change: DiffLine.Kind) -> UIColor {
        switch change {
        case .addition: return theme.addBackground
        case .deletion: return theme.deleteBackground
        case .context: return theme.background
        }
    }

    private func lineNumberColor(for change: DiffLine.Kind) -> UIColor {
        switch change {
        case .addition: return theme.addTint
        case .deletion: return theme.deleteTint
        case .context: return theme.mutedText
        }
    }

    /// Alternating 1 pt stripes so a deletion reads without relying on red alone.
    private func drawDeleteStripes(rect: CGRect, context: CGContext) {
        theme.deleteTint.setFill()
        var y = rect.minY
        while y < rect.maxY {
            context.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1))
            y += 2
        }
    }

    // MARK: - Glyphs

    private func drawDisclosureChevron(rect: CGRect, color: UIColor, collapsed: Bool, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if collapsed {
            context.move(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.28))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.60, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.maxY - rect.height * 0.28))
        } else {
            context.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.42))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.62))
            context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.height * 0.42))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawFileIcon(rect: CGRect, changeKind: GitFile.ChangeKind, context: CGContext) {
        let color = theme.tint(for: changeKind)
        let outline = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        color.setStroke()
        outline.lineWidth = 2
        outline.stroke()

        if changeKind == .renamed {
            drawRenameChevrons(rect: rect.insetBy(dx: 4.5, dy: 5), color: color, context: context)
            return
        }
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
    }

    private func drawRenameChevrons(rect: CGRect, color: UIColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let chevronWidth = min(rect.width * 0.28, 3.6)
        let chevronHeight = min(rect.height, 8)
        let gap = min(rect.width * 0.18, 2.4)
        let startX = rect.midX - (chevronWidth * 2 + gap) / 2
        for x in [startX, startX + chevronWidth + gap] {
            context.move(to: CGPoint(x: x, y: rect.midY - chevronHeight / 2))
            context.addLine(to: CGPoint(x: x + chevronWidth, y: rect.midY))
            context.addLine(to: CGPoint(x: x, y: rect.midY + chevronHeight / 2))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawViewedCheckbox(rect: CGRect, checked: Bool, context: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        if checked {
            theme.accent.setFill()
            path.fill()
        }
        (checked ? theme.accent : theme.mutedText).setStroke()
        path.lineWidth = 1.8
        path.stroke()
        guard checked else { return }

        context.saveGState()
        context.setStrokeColor(theme.background.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
        context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.maxY - rect.height * 0.30))
        context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY + rect.height * 0.30))
        context.strokePath()
        context.restoreGState()
    }

    private func drawNoticeIcon(rect: CGRect, color: UIColor, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.7)
        context.setLineCap(.round)
        context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
        context.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.30))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.58))
        context.strokePath()
        color.setFill()
        context.fillEllipse(in: CGRect(x: rect.midX - 1, y: rect.maxY - rect.height * 0.30, width: 2, height: 2))
        context.restoreGState()
    }

    // MARK: - Text

    private func drawText(_ text: String, at point: CGPoint, color: UIColor, font: UIFont) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color, .ligature: 0])
    }

    private func drawSingleLineText(
        _ text: String,
        rect: CGRect,
        color: UIColor,
        font: UIFont,
        horizontalOffset: CGFloat = 0,
        context: CGContext
    ) {
        context.saveGState()
        context.clip(to: rect)
        (text as NSString).draw(
            at: CGPoint(x: rect.minX - horizontalOffset, y: rect.midY - font.lineHeight / 2),
            withAttributes: [.font: font, .foregroundColor: color, .ligature: 0]
        )
        context.restoreGState()
    }

    private func drawRightAlignedText(_ text: String, rect: CGRect, color: UIColor, font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
