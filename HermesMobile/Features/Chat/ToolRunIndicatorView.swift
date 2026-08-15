import SwiftUI

/// Per-tool running indicator: a ring plus three short lines whose opacity
/// travels left→right while the tool is in flight, resolving to a green check
/// or red cross when it finishes.
///
/// **Cost model (load-bearing).** Every *running* row publishes an empty
/// leading slot's bounds through `ToolRunIndicatorAnchors`, and the enclosing
/// block paints all of them from a *single* `TimelineView` + `Canvas` overlay.
/// One animated layer per block, regardless of how many tools run at once —
/// N per-row timelines is the shape that produced a measured 78% CPU on the
/// gallery's worst case. Text stays outside the timeline so row bodies do not
/// re-evaluate at 30fps.
///
/// The schedule is `ThinkingOrbView.schedule()` for the same reason documented
/// there: only `.animation(minimumInterval:paused:)` responds to SwiftUI's
/// low-frequency mode, and the transcript stacks rows eagerly.
enum ToolRunIndicator {
    /// Fixed slot the row reserves; the overlay draws inside it.
    ///
    /// Sized to hold the ring *and* its stroke: the ring is stroked, so half
    /// the line width falls outside the circle's own bounds. Drawing at
    /// `rect.minX` therefore put 0.9pt of the ring outside the slot, which the
    /// row's leading edge clipped. `ringInset` keeps the whole mark inside.
    static let slotWidth: CGFloat = 26
    static let slotHeight: CGFloat = 14

    static let ringDiameter: CGFloat = 10
    static let ringStroke: CGFloat = 1.8
    /// Half the stroke, so the outer edge of the ring lands on the slot edge.
    static var ringInset: CGFloat { ringStroke / 2 }
    static let lineCount = 3

    /// One traveling sweep, in seconds.
    static let cycleDuration: Double = 1.3

    /// Stagger between rows so a parallel batch doesn't pulse in lockstep.
    static let rowPhaseOffset: Double = 0.16

    /// Static phase for Reduce Motion (mid-sweep, non-degenerate).
    static let staticPhase: Double = 0.35

    static func draw(
        context: GraphicsContext,
        rect: CGRect,
        phase: Double,
        color: Color
    ) {
        let ringRect = CGRect(
            x: rect.minX + ringInset,
            y: rect.midY - ringDiameter / 2,
            width: ringDiameter,
            height: ringDiameter
        )
        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(color),
            lineWidth: ringStroke
        )

        // Three stacked lines to the right of the ring, middle longest so the
        // mark reads as a centred flare rather than a lopsided wedge.
        //
        // Each line is a stroke whose head grows left→right to full width,
        // then whose tail catches up and retracts into the head, so the line
        // draws itself on and then vanishes from the back before cycling.
        // Head and tail are the same eased ramp, offset in time; clamping
        // keeps the tail behind the head so the segment never inverts.
        let lineX = ringRect.maxX + 3
        let widths: [CGFloat] = [6.5, 9, 5]
        let spacing: CGFloat = 3.5
        let top = rect.midY - spacing

        for index in 0..<lineCount {
            let local = wrap(phase - Double(index) * lineStagger)
            let head = ease(min(1, local / headSpan))
            let tail = ease(max(0, (local - tailDelay) / (1 - tailDelay)))

            let width = widths[index]
            let startX = lineX + width * CGFloat(min(tail, head))
            let endX = lineX + width * CGFloat(head)

            // Sub-pixel segments read as flicker; drop them instead.
            guard endX - startX > 0.35 else { continue }

            let y = top + CGFloat(index) * spacing
            var line = Path()
            line.move(to: CGPoint(x: startX, y: y))
            line.addLine(to: CGPoint(x: endX, y: y))

            // Fade only as the tail closes, so the stroke leaves rather than
            // blinking out at full strength.
            let remaining = 1 - min(tail, head) / max(head, 0.0001)
            let opacity = 0.30 + 0.70 * min(1, max(0, remaining))

            context.stroke(
                line,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
        }
    }

    /// Fraction of the cycle the head takes to reach full width; the rest of
    /// the cycle is the tail retracting into it.
    private static let headSpan: Double = 0.55
    /// When the tail starts chasing the head.
    private static let tailDelay: Double = 0.42
    /// Per-line delay so the three lines sweep in sequence.
    private static let lineStagger: Double = 0.12

    private static func wrap(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    /// Smoothstep — the ends of each sweep settle instead of snapping.
    private static func ease(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    static func phase(time: Double, rowIndex: Int) -> Double {
        let base = time / cycleDuration - Double(rowIndex) * rowPhaseOffset
        return base - base.rounded(.down)
    }
}

/// Bounds of each running row's indicator slot, collected by the block.
struct ToolRunIndicatorAnchors: PreferenceKey {
    struct Entry: Equatable {
        let id: String
        let rowIndex: Int
        let anchor: Anchor<CGRect>
    }

    static var defaultValue: [Entry] = []

    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) {
        value += nextValue()
    }
}

/// The leading slot a tool row reserves for its indicator.
///
/// Running rows publish their bounds and draw nothing themselves; settled rows
/// draw a static glyph locally (a one-shot spring, not a live layer).
struct ToolRunIndicatorSlot: View {
    let toolCall: ToolCall
    let rowIndex: Int
    /// False when the enclosing block is settled, so a never-completed call in
    /// a finished group doesn't animate forever.
    var isBlockActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    /// Running tint follows the app accent so the mark belongs to the palette
    /// rather than being a hardcoded orange in an otherwise tokenised surface.
    private var tint: Color { HeaderLogoColor.color(for: headerLogoColorHex) }

    var body: some View {
        Group {
            switch status {
            case .running:
                if reduceMotion {
                    Canvas { [tint] context, size in
                        ToolRunIndicator.draw(
                            context: context,
                            rect: CGRect(origin: .zero, size: size),
                            phase: ToolRunIndicator.staticPhase,
                            color: tint
                        )
                    }
                } else {
                    // Bounds only; the block-level overlay paints this slot.
                    Color.clear
                        .anchorPreference(key: ToolRunIndicatorAnchors.self, value: .bounds) { anchor in
                            [.init(id: toolCall.id, rowIndex: rowIndex, anchor: anchor)]
                        }
                }
            case .waiting:
                Circle()
                    .strokeBorder(palette.textTertiary, lineWidth: 1.5)
                    .frame(width: ToolRunIndicator.ringDiameter, height: ToolRunIndicator.ringDiameter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .succeeded:
                settledGlyph("checkmark.circle.fill", color: .green)
            case .failed:
                settledGlyph("xmark.circle.fill", color: .red)
            }
        }
        .frame(width: ToolRunIndicator.slotWidth, height: ToolRunIndicator.slotHeight, alignment: .leading)
        .accessibilityHidden(true)
    }

    private enum Status {
        case running, waiting, succeeded, failed
    }

    private var status: Status {
        if toolCall.isCompleted {
            return toolCall.isError == true ? .failed : .succeeded
        }
        return isBlockActive ? .running : .waiting
    }

    /// Fire-and-forget landing animation: scales in once and then costs
    /// nothing, unlike a persistent animated layer.
    private func settledGlyph(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.8).combined(with: .opacity)
            )
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle(rawValue: backgroundStyleRawValue) ?? .defaultValue,
            temperature: ChatPaletteTemperature(rawValue: paletteTemperatureRawValue) ?? .defaultValue
        )
    }
}

/// Paints every running indicator in a block from one timeline.
struct ToolRunIndicatorOverlay: ViewModifier {
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    func body(content: Content) -> some View {
        let tint = HeaderLogoColor.color(for: headerLogoColorHex)
        return overlayBody(content: content, tint: tint)
    }

    private func overlayBody(content: Content, tint: Color) -> some View {
        content.overlayPreferenceValue(ToolRunIndicatorAnchors.self) { entries in
            if entries.isEmpty {
                // No running rows: no overlay, so the timeline is torn down
                // with it and nothing keeps ticking.
                Color.clear.allowsHitTesting(false)
            } else {
                GeometryReader { proxy in
                    TimelineView(ThinkingOrbView.schedule()) { timeline in
                        Canvas { context, _ in
                            let time = timeline.date.timeIntervalSinceReferenceDate
                            for entry in entries {
                                ToolRunIndicator.draw(
                                    context: context,
                                    rect: proxy[entry.anchor],
                                    phase: ToolRunIndicator.phase(time: time, rowIndex: entry.rowIndex),
                                    color: tint
                                )
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Applied by a tool block to paint its running rows' indicators.
    func toolRunIndicatorOverlay() -> some View {
        modifier(ToolRunIndicatorOverlay())
    }
}
