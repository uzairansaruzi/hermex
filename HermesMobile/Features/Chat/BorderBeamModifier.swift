import SwiftUI

// BorderBeamModifier is a SwiftUI port of the traveling-beam family of the
// "border-beam" React component by Jakub Antalik —
// https://github.com/Jakubantalik/border-beam (MIT License). The traveling
// glow — an angular-gradient stroke whose bright segment rotates around the
// shape — mirrors the upstream `rotate` presets; the pulse family is
// intentionally not ported, and upstream's blurred bloom pass was dropped
// because it cost an offscreen render per capsule per frame. Like upstream's
// "relies on the element's own border" behavior, the resting state draws
// nothing — the wrapped view's own hairline remains the idle edge.
// See Resources/ThirdPartyNotices/NOTICE.txt.

/// Style input for `.borderBeam`. Views normally build this from
/// `ActivityBeamStyle.resolved(palette:colorScheme:accent:)` in
/// `ChatPalette.swift`; the initializer stays public-shaped so galleries and
/// previews can construct one directly.
struct BeamStyle: Equatable {
    /// Visible gradient stops of the traveling segment. The renderer fades
    /// the segment's head and tail to clear itself.
    var colors: [Color]
    /// Seconds for one full trip around the shape.
    var cycleDuration: Double
    /// 0–1 multiplier applied to all beam opacities.
    var strength: Double

    var isVisible: Bool { strength > 0 && !colors.isEmpty }

    init(colors: [Color], cycleDuration: Double, strength: Double) {
        self.colors = colors
        self.cycleDuration = cycleDuration
        self.strength = strength
    }

    init(resolved: ResolvedBeam) {
        self.init(
            colors: resolved.colors,
            cycleDuration: max(0.5, resolved.cycleDuration),
            strength: resolved.strength
        )
    }
}

private struct BorderBeamModifier<BeamShape: InsettableShape>: ViewModifier {
    let style: BeamStyle
    let shape: BeamShape
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Keeps the beam mounted while it fades out.
    ///
    /// Without this the `else if active` below removes the `TimelineView` on
    /// the same update that flips `active` to false, so the opacity animation
    /// has nothing left to render and the glow pops instead of fading. This
    /// stays true until the fade has finished, then unmounts so an inactive
    /// capsule stops scheduling frames.
    @State private var isRenderingBeam = false

    /// Fraction of the full circle occupied by the bright segment.
    private static var segmentSpan: Double { 0.12 }
    private static var lineWidth: CGFloat { 1.5 }
    private static var fadeDuration: Double { 0.4 }

    func body(content: Content) -> some View {
        content
            .overlay {
                if style.isVisible {
                    beamOverlay
                        .opacity(active ? 1 : 0)
                        .animation(.easeOut(duration: Self.fadeDuration), value: active)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { isRenderingBeam = active }
            .onChange(of: active) { _, nowActive in
                if nowActive {
                    isRenderingBeam = true
                } else if !reduceMotion {
                    // Hold the strokes on screen for exactly the fade, then
                    // drop them so no frames are scheduled while idle.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.fadeDuration))
                        guard !active else { return }
                        isRenderingBeam = false
                    }
                } else {
                    isRenderingBeam = false
                }
            }
    }

    @ViewBuilder
    private var beamOverlay: some View {
        if reduceMotion {
            // Static faint full ring instead of motion.
            shape
                .strokeBorder(
                    staticRingColor,
                    lineWidth: Self.lineWidth
                )
        } else if active || isRenderingBeam {
            // Same capped cadence as the orbs. Uses the animation schedule so
            // the beam stops updating when the capsule isn't being drawn.
            TimelineView(ThinkingOrbView.schedule()) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 86_400)
                let phase = (t / style.cycleDuration)
                    .truncatingRemainder(dividingBy: 1)
                beamStrokes(phase: phase)
            }
        }
    }

    /// The average beam color at reduced opacity for the Reduce Motion ring.
    private var staticRingColor: Color {
        (style.colors.first ?? .secondary).opacity(0.35 * style.strength)
    }

    private func beamStrokes(phase: Double) -> some View {
        let gradient = beamGradient(phase: phase)
        // Each angular-gradient stroke is a full shaded pass, so the number of
        // strokes — not the blur — dominates cost when many capsules animate.
        // A single slightly-wider stroke carries the glow readably.
        //
        // `drawingGroup` is load-bearing despite there being one child layer:
        // it rasterizes the animating gradient once per frame instead of
        // re-shading it through the overlay/opacity chain. Measured on the
        // gallery's 10-capsule page, removing it costs 14.1% -> 28.1% CPU.
        // Do not delete it as redundant without re-measuring.
        return shape
            .strokeBorder(gradient, lineWidth: Self.lineWidth + 1)
            .opacity(style.strength)
            .drawingGroup()
    }

    /// Angular gradient that is clear except for a short bright segment whose
    /// interior stops carry the style's colors, rotated by `phase`.
    private func beamGradient(phase: Double) -> AngularGradient {
        let span = Self.segmentSpan
        var stops: [Gradient.Stop] = []
        let leading = style.colors.first ?? .clear
        let trailing = style.colors.last ?? .clear

        stops.append(.init(color: .clear, location: 0))
        stops.append(.init(color: leading.opacity(0), location: 0.0001))

        // Interior color stops spread across the segment.
        let count = style.colors.count
        if count == 1 {
            stops.append(.init(color: style.colors[0], location: span / 2))
        } else {
            for (index, color) in style.colors.enumerated() {
                // Keep a small fade-in/out margin at the segment edges.
                let f = Double(index) / Double(count - 1)
                let location = span * (0.12 + 0.76 * f)
                stops.append(.init(color: color, location: location))
            }
        }

        stops.append(.init(color: trailing.opacity(0), location: span))
        stops.append(.init(color: .clear, location: 1))

        return AngularGradient(
            gradient: Gradient(stops: stops),
            center: .center,
            angle: .degrees(phase * 360 - 90)
        )
    }
}

extension View {
    /// Overlays a traveling border glow on the given shape while `active`.
    /// When inactive the beam fades out completely — the view's own border
    /// remains the idle edge. Honors Reduce Motion with a static faint ring.
    func borderBeam(
        style: BeamStyle,
        shape: some InsettableShape,
        active: Bool
    ) -> some View {
        modifier(BorderBeamModifier(style: style, shape: shape, active: active))
    }
}

#if DEBUG
#Preview("Border beam") {
    VStack(spacing: 24) {
        Text("Thinking…")
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .borderBeam(
                style: BeamStyle(
                    colors: [.white.opacity(0.4), .white, .white.opacity(0.4)],
                    cycleDuration: 2.6,
                    strength: 0.7
                ),
                shape: Capsule(),
                active: true
            )

        Text("Aurora")
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .borderBeam(
                style: BeamStyle(
                    colors: [.teal, .blue, .purple],
                    cycleDuration: 3.0,
                    strength: 0.8
                ),
                shape: Capsule(),
                active: true
            )
    }
    .padding(40)
    .background(Color.black)
}
#endif
