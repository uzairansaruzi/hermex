import SwiftUI

// ThinkingOrbView is a SwiftUI/Canvas port of the "thinking orbs" dotted
// 3D spinners by Jakub Antalik — https://github.com/Jakubantalik/thinking-orbs
// (MIT License). The math (deterministic hash, tilted-orbit particles, the
// scan-meridian globe, the constellation web, the three-strand braid, and
// the undulating ribbon) is ported faithfully from
// src/engine/{core,orbits,lattice,web,braid,ribbon}.ts using the size-20
// inline presets from src/presets.ts. See Resources/ThirdPartyNotices/NOTICE.txt.

enum ThinkingOrbState {
    case thinking
    case working
    case searching
    case writing
    case connecting
    /// Shell / execute work. Dotted outline cycling circle → triangle →
    /// square: a shape being formed, which reads as "running something"
    /// better than the generic orbit field did.
    case shaping
    /// Deterministic, converging work — tests, builds, diffs. A dot sphere
    /// whose bands scramble in quarter turns and then click back to solved.
    case solving
    /// Waiting on the user or an external party: approvals, clarifications.
    case listening

    /// Maps a tool name to the orb that best matches the activity.
    ///
    /// `.thinking` is reserved for reasoning streams and never maps here.
    ///
    /// **Order is the whole design.** These are substring tests over an
    /// unbounded vocabulary, so the earlier a bucket sits the more it
    /// captures. The sequence runs most-specific to least: a name like
    /// `run_tests_in_shell` should read as testing, not shell, so `solving`
    /// is checked before `shaping`.
    ///
    /// `.working` is the residual. It used to absorb everything that was not
    /// an edit, a search, or a network call — which in practice meant most
    /// shell and test tools wore a generic orb. The buckets below exist to
    /// pull the common cases out of it.
    static func forTool(name: String?) -> ThinkingOrbState {
        let name = name?.lowercased() ?? ""

        // Waiting on a human. First because these are interrupts: whatever
        // else the name says, the turn is blocked on someone answering.
        let listening = ["approval", "approve", "clarif", "confirm", "ask_user", "prompt_user", "permission", "elicit"]
        if listening.contains(where: { name.contains($0) }) {
            return .listening
        }

        // Converging work with a pass/fail end state.
        let solving = ["test", "build", "compile", "lint", "typecheck", "diff", "verify", "validate", "check", "xcodebuild", "pytest"]
        if solving.contains(where: { name.contains($0) }) {
            return .solving
        }

        // Producing or changing content.
        let writing = ["write", "edit", "create", "apply_patch", "patch", "insert", "replace", "append", "rename", "delete", "move", "mkdir", "format"]
        if writing.contains(where: { name.contains($0) }) {
            return .writing
        }

        // Looking something up. After `writing` so `edit_file` is not caught
        // by `file`-adjacent search words.
        let searching = ["search", "read", "grep", "list", "web", "find", "glob", "fetch", "view", "lookup", "query", "browse", "inspect", "cat", "ls"]
        if searching.contains(where: { name.contains($0) }) {
            return .searching
        }

        // Talking to something else over a wire.
        let connecting = ["network", "server", "session", "connect", "http", "request", "api", "curl", "clone", "push", "pull", "upload", "download", "deploy", "mcp"]
        if connecting.contains(where: { name.contains($0) }) {
            return .connecting
        }

        // Executing. Last of the named buckets because `run`/`exec` appear
        // inside many compound names that belong to an earlier bucket.
        let shaping = ["shell", "bash", "exec", "run", "command", "terminal", "process", "script", "python", "node", "npm", "git"]
        if shaping.contains(where: { name.contains($0) }) {
            return .shaping
        }

        return .working
    }
}

/// An animated, monochrome dotted-3D orb used in reasoning/tool activity
/// headers while work is in flight. Renders with a 30 fps `TimelineView`
/// animation schedule plus `Canvas`; honors Reduce Motion by drawing a
/// single static frame.
struct ThinkingOrbView: View {
    let state: ThinkingOrbState
    var size: CGFloat = 20
    var color: Color = .secondary
    var paused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Animation cadence for the live orb. Ambient status marks read the same
    /// at 30 fps as at the display's native rate, and capping the interval
    /// keeps several simultaneous orbs from saturating the CPU.
    static let frameInterval: Double = 1.0 / 30.0

    /// Shared cadence for every animating orb, beam, and shimmer.
    ///
    /// This is deliberately `.animation(minimumInterval:paused:)` and not a
    /// `PeriodicTimelineSchedule`: only the animation schedule responds to
    /// SwiftUI's low-frequency mode, so it stops producing updates when the
    /// view isn't being drawn. The transcript stacks rows eagerly, so an
    /// active reasoning/tool capsule stays alive after it scrolls away — a
    /// periodic schedule keeps ticking for those, trading a small on-screen
    /// CPU win for off-screen battery drain in long sessions.
    static func schedule(paused: Bool = false) -> AnimationTimelineSchedule {
        .animation(minimumInterval: frameInterval, paused: paused)
    }

    /// Fixed timestamp used for the static Reduce Motion frame. Per mode:
    /// mid-phase frames chosen by eye in the surface gallery so the frozen
    /// pose is not degenerate (braid strands mid-plait, ribbon mid-wave).
    private static func staticTime(for state: ThinkingOrbState) -> Double {
        switch state {
        case .thinking, .writing:
            2.6
        case .working, .searching, .connecting:
            1.7
        case .shaping:
            // Mid-hold rather than mid-blend: a frozen half-morph is an
            // unreadable blob, whereas a held shape is a clean silhouette.
            0.7
        case .solving:
            // Mid-scramble, so some bands sit visibly off-axis.
            2.2
        case .listening:
            1.1
        }
    }

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, canvasSize in
                    Self.draw(
                        context: context,
                        size: min(canvasSize.width, canvasSize.height),
                        state: state,
                        time: Self.staticTime(for: state),
                        color: color
                    )
                }
            } else {
                // Capping at 30 fps keeps several simultaneous orbs from
                // saturating the CPU; an uncapped schedule would redraw the
                // full dot solve at the display's rate (120 Hz on ProMotion).
                // `paused` freezes on the last drawn frame rather than jumping
                // to a canned pose, which keeps the completion cross-dissolve
                // continuous.
                TimelineView(Self.schedule(paused: paused)) { timeline in
                    Canvas { context, canvasSize in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 86_400)
                        Self.draw(
                            context: context,
                            size: min(canvasSize.width, canvasSize.height),
                            state: state,
                            time: t,
                            color: color
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Shared geometry primitives (port of engine/core.ts)

    /// A projected dot ready to paint. `opacity` folds the original ink
    /// value ("white") and alpha into a single tint opacity: on paper,
    /// ink 0 (darkest) is equivalent to full-opacity tint, so
    /// `opacity = alpha * (1 - white)` preserves the depth language in a
    /// single accent color on both light and dark surfaces.
    private struct Dot {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        var opacity: Double
    }

    private struct Line {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
        var opacity: Double
        var width: Double
    }

    /// Deterministic hash in [0, 1). Port of `hashD`.
    private static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    private static func frac(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    private static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double {
        a + (b - a) * f
    }

    /// Value noise on a 2D lattice. Port of `vnoise`.
    private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = x.rounded(.down)
        let yi = y.rounded(.down)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi)
        let b = hashD(xi + 1, yi)
        let c = hashD(xi, yi + 1)
        let d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    /// Stable directions on a unit sphere (Fibonacci lattice). Port of `fibDir`.
    private static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = (1 - y * y).squareRoot()
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    /// Shortest signed angular distance, wrapped to (-π, π]. Port of `angleDelta`.
    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// Shared spin + tilt + orthographic projection. Port of `makeProj`.
    private static func makeProj(
        yaw: Double,
        tilt: Double,
        cx: Double,
        cy: Double,
        scale: Double
    ) -> (Double, Double, Double) -> (Double, Double, Double) {
        let st = sin(tilt)
        let ct = cos(tilt)
        let sy = sin(yaw)
        let cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// Dot radii were tuned for a 300pt frame; sub-linear scaling keeps
    /// small spinners legible. Port of `radiusScale`.
    private static func radiusScale(size: Double, pow exponent: Double) -> Double {
        Foundation.pow(size / 300, exponent)
    }

    /// Painter: z-sort far→near, tinted matte dots. Port of `paint`.
    private static func paint(
        context: GraphicsContext,
        dots: [Dot],
        color: Color,
        rMin: Double = 0.3
    ) {
        // Drop invisible dots before sorting: at small sizes a large share of
        // the ghost sphere falls under the alpha floor, so filtering first
        // shrinks the sort and skips their fills entirely.
        var visible = dots.filter { $0.opacity >= 0.02 }
        // `sort()` in place on our own buffer avoids the second array that
        // `sorted(by:)` allocates every frame.
        visible.sort { $0.z < $1.z }

        // Quantizing opacity keeps the set of distinct colors handed to the
        // renderer small (64 instead of one per dot), which is cheaper to
        // resolve. Each dot is still filled individually — batching by bucket
        // would reorder draws and break the far-to-near depth stacking.
        for dot in visible {
            let r = max(rMin, dot.r)
            let rect = CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(color.opacity(Self.quantized(dot.opacity)))
            )
        }
    }

    /// Snaps an opacity to one of 64 steps. Identical on screen, but it keeps
    /// the resolved-color set small enough for the renderer to reuse.
    private static func quantized(_ opacity: Double) -> Double {
        let clamped = min(1, max(0, opacity))
        return (clamped * 64).rounded() / 64
    }

    /// Stroke pass for edge-based modes; runs before `paint` so nodes sit
    /// on top. Port of `paintLines`.
    private static func paintLines(context: GraphicsContext, lines: [Line], color: Color) {
        for line in lines {
            guard line.opacity >= 0.02 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: line.x1, y: line.y1))
            path.addLine(to: CGPoint(x: line.x2, y: line.y2))
            context.stroke(
                path,
                with: .color(color.opacity(min(1, line.opacity))),
                lineWidth: line.width
            )
        }
    }

    private static func draw(
        context: GraphicsContext,
        size: Double,
        state: ThinkingOrbState,
        time: Double,
        color: Color
    ) {
        switch state {
        case .thinking:
            drawBraid(context: context, size: size, time: time, color: color)
        case .working:
            drawOrbits(context: context, size: size, time: time, color: color)
        case .searching:
            drawGlobe(context: context, size: size, time: time, color: color)
        case .writing:
            drawRibbon(context: context, size: size, time: time, color: color)
        case .connecting:
            drawWeb(context: context, size: size, time: time, color: color)
        case .shaping:
            drawMorph(context: context, size: size, time: time, color: color)
        case .solving:
            drawRubik(context: context, size: size, time: time, color: color)
        case .listening:
            drawWave(context: context, size: size, time: time, color: color)
        }
    }

    // MARK: - Thinking: three-strand plait (port of engine/braid.ts, size-20 preset)

    private static func drawBraid(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 2.75, count ×0.1125, radius ×1.36.
        let t = time * 2.75
        let strandN = 6       // round(52 × 0.1125)
        let ghostN = 17       // round(150 × 0.1125)
        let turns = 3.0
        let rBase = 1.2 * 1.36
        let rDepth = 1.8 * 1.36

        let cx = size / 2
        let cy = size / 2
        let bigR = (size / 2) * 0.76
        let pt = makeProj(yaw: t * 0.4, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size: size, pow: 0.6)

        var dots: [Dot] = []
        dots.reserveCapacity(ghostN + 3 * strandN)

        // Faint fibonacci ghost sphere behind the plait.
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * bigR, d.1 * bigR, d.2 * bigR)
            let depth = (z / bigR + 1) / 2
            dots.append(Dot(
                x: px,
                y: py,
                z: z,
                r: 0.8 * rs,
                opacity: (0.1 + 0.22 * depth) * (1 - 0.78)
            ))
        }

        // Each strand runs pole to pole on a helix; a radial breathing term
        // makes them trade places, reading as the over/under of a plait.
        for s in 0..<3 {
            let phase = (Double(s) / 3) * 2 * .pi
            for i in 0..<strandN {
                // u walks pole to pole; the frac() drift slides the whole
                // strand along.
                let u = (frac(Double(i) / Double(strandN) + t * 0.045) * 2 - 1) * 0.96
                let surf = max(0, 1 - u * u).squareRoot()
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let a = u * .pi * turns + phase
                // Radial breathing: strands trade places — the over/under.
                let weave = 1 + 0.075 * sin(u * .pi * turns * 2 + phase * 2 + t * 0.8)
                let rr = surf * bigR * weave
                let (px, py, zr) = pt(cos(a) * rr, u * bigR * weave, sin(a) * rr)
                let depth = (zr / bigR + 1) / 2
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: zr,
                    r: (rBase + rDepth * depth) * rs,
                    opacity: endFade * (0.45 + 0.55 * depth) * (1 - (0.55 - 0.45 * depth))
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Writing: undulating sash (port of engine/ribbon.ts, size-20 preset)

    private static func drawRibbon(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 3.12, count ×0.051 (√-split across the
        // lanes/segs pair), radius ×1.073, extras spin 0 / bandMul 4.94 /
        // wobMul 1. spin 0 freezes the band's 3D tumble, leaving only the
        // traveling undulation. Only the ribbon path is ported (faceOn 0);
        // the ring variant is a separate mode upstream.
        let t = time * 3.12
        let lanes = 10        // max(1, round(max(2, round(5 × √0.051)) × 4.94))
        let segs = 20         // max(2, round(88 × √0.051))
        let ghostN = 8        // round(150 × 0.051)
        let rBase = 1.1 * 1.073
        let rDepth = 1.7 * 1.073
        let wobMul = 1.0
        let spin = 0.0

        let cx = size / 2
        let cy = size / 2
        let bigR = (size / 2) * 0.78
        let camTilt = 0.3
        let pt = makeProj(yaw: t * 0.1 * spin, tilt: camTilt, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size: size, pow: 0.6)

        var dots: [Dot] = []
        dots.reserveCapacity(ghostN + lanes * segs)

        // Faint fibonacci ghost sphere behind the sash.
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * bigR, d.1 * bigR, d.2 * bigR)
            let depth = (z / bigR + 1) / 2
            dots.append(Dot(
                x: px,
                y: py,
                z: z,
                r: 0.8 * rs,
                opacity: (0.1 + 0.22 * depth) * (1 - 0.78)
            ))
        }

        // The band plane, precessing (frozen while spin = 0).
        let ya = t * 0.24 * spin
        let ta = 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya)
        let uy = 0.0
        let uz = sin(ya)
        let vx = -uz * sin(ta)
        let vy = cos(ta)
        let vz = ux * sin(ta)
        // Plane normal n = u × v.
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<segs {
                let a = (Double(k) / Double(segs)) * 2 * .pi
                // The undulation: two traveling waves along the band.
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22)
                    + 0.07 * sin(a * 5 + t * 1.1)) * wobMul
                let off = laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let (px, py, zr) = pt(x / l * bigR, y / l * bigR, z / l * bigR)
                let depth = (zr / bigR + 1) / 2
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: zr,
                    r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
                    opacity: (0.4 + 0.6 * depth) * (1 - (0.52 - 0.44 * depth + 0.18 * edge))
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Working: tilted orbits (port of engine/orbits.ts, size-20 preset)

    private static func drawOrbits(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 3.9, count ×0.238, radius ×2.4.
        let t = time * 3.9
        let orbitN = 3        // round(12 × 0.238)
        let ghostN = 10       // round(40 × 0.238)
        let particles = 3     // flat option, not count-scaled
        let ghostR = 0.9 * 2.4
        let ghostA = 0.5
        let partR = 1.2 * 2.4
        let partRDepth = 1.6 * 2.4

        let cx = size / 2
        let cy = size / 2
        let bigR = (size / 2) * 0.82
        let pt = makeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size: size, pow: 0.6)

        var dots: [Dot] = []
        dots.reserveCapacity(orbitN * (ghostN + particles))

        for orb in 0..<orbitN {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = bigR * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            // Orbit plane basis (u, v ⟂ normal n).
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            // Ghost path.
            for k in 0..<ghostN {
                let a = (Double(k) / Double(ghostN)) * 2 * .pi
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: z,
                    r: ghostR * rs,
                    opacity: ghostA * (0.4 + 0.6 * depth) * (1 - 0.72)
                ))
            }

            // The particles doing the work.
            for m in 0..<particles {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: z,
                    r: (partR + partRDepth * depth) * rs,
                    opacity: 1 - (0.3 - 0.22 * depth)
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Searching: scan-meridian globe (port of engine/lattice.ts drawGlobe, size-20 preset)

    private static func drawGlobe(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 2.665, count ×0.105 (√-split across the
        // lat/lon pair), radius ×1.75, scanMul 4.335, dimBase 0.45.
        let t = time * 2.665
        let latRings = 6      // round(17 × √0.105)
        let lonDensity = 14.0 // round(44 × √0.105)
        let rBase = 0.6 * 1.75
        let rDepth = 1.7 * 1.75
        let rBoost = 1.0 * 1.75
        let inkFar = 0.62
        let inkSpan = 0.54
        let scanMul = 4.335
        let dimBase = 0.45

        let spin = 0.5
        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = makeProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        // The scan sweeps relative to the spin; scanMul scales that rate.
        let scan = t * (spin + (1.7 - spin) * scanMul)
        let rs = radiusScale(size: size, pow: 0.6)

        var dots: [Dot] = []
        dots.reserveCapacity((latRings + 1) * Int(lonDensity))

        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                // The scan: a moving meridian read as a size ripple.
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                let white = inkFar - inkSpan * depth
                let alpha = dimBase + (1 - dimBase) * min(1, boost)
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: z,
                    r: (rBase + rDepth * depth + rBoost * boost) * rs,
                    opacity: alpha * (1 - white)
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Connecting: constellation web (port of engine/web.ts, size-20 preset)

    private static func drawWeb(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 6.63, count ×0.25, radius ×1.52.
        let t = time * 6.63
        let nodeN = 8         // round(30 × 0.25)
        let signals = 1       // round(5 × 0.25)
        let thr = 0.72
        let nodeR = 1.4 * 1.52
        let nodeRDepth = 1.8 * 1.52
        let lineW = 0.8

        let cx = size / 2
        let cy = size / 2
        let bigR = (size / 2) * 0.8
        // The projector carries the radius as its scale, so node vectors stay
        // unit-length and distances below are in unit-sphere space.
        let pt = makeProj(yaw: t * 0.12, tilt: 0.32, cx: cx, cy: cy, scale: bigR)
        let rs = radiusScale(size: size, pow: 0.6)

        // Nodes: fib lattice + slow noise wander, renormalized to the surface.
        var nodes: [(Double, Double, Double)] = []
        nodes.reserveCapacity(nodeN)
        for i in 0..<nodeN {
            let d = fibDir(i, nodeN)
            let x = d.0 + 0.3 * (vnoise(Double(i) * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (vnoise(Double(i) * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (vnoise(Double(i) * 0.77 + 55, t * 0.27) - 0.5) * 2
            let l = (x * x + y * y + z * z).squareRoot()
            nodes.append((x / l, y / l, z / l))
        }

        var lines: [Line] = []
        var dots: [Dot] = []
        dots.reserveCapacity(nodeN + signals)

        // Edges between close neighbours, alpha by proximity + depth.
        for i in 0..<nodeN {
            for j in (i + 1)..<nodeN {
                let dx = nodes[i].0 - nodes[j].0
                let dy = nodes[i].1 - nodes[j].1
                let dz = nodes[i].2 - nodes[j].2
                let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard dist < thr else { continue }
                let (x1, y1, z1) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
                let (x2, y2, z2) = pt(nodes[j].0, nodes[j].1, nodes[j].2)
                let depth = ((z1 + z2) / 2 + 1) / 2
                lines.append(Line(
                    x1: x1,
                    y1: y1,
                    x2: x2,
                    y2: y2,
                    opacity: (1 - dist / thr) * (0.3 + 0.55 * depth) * (1 - 0.42),
                    width: max(0.6, lineW * rs)
                ))
            }
        }

        for i in 0..<nodeN {
            let (px, py, z) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
            let depth = (z + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
            dots.append(Dot(
                x: px,
                y: py,
                z: z,
                r: (nodeR + nodeRDepth * depth) * pulse * rs,
                opacity: 1 - (0.55 - 0.45 * depth)
            ))
        }

        // Signals: bright packets running between paired nodes.
        for s in 0..<signals {
            let phase = t * 0.55 + Double(s) * 7.31
            let seg = phase.rounded(.down)
            let a = Int(hashD(seg, Double(s) * 3.1 + 1.7) * Double(nodeN))
            let b = Int(hashD(seg, Double(s) * 5.7 + 4.2) * Double(nodeN))
            guard a != b, a < nodeN, b < nodeN else { continue }
            let f = frac(phase)
            let x = lerp(nodes[a].0, nodes[b].0, f)
            let y = lerp(nodes[a].1, nodes[b].1, f)
            let z = lerp(nodes[a].2, nodes[b].2, f)
            let l = max(1e-6, (x * x + y * y + z * z).squareRoot())
            let (px, py, zr) = pt(x / l, y / l, z / l)
            let depth = (zr + 1) / 2
            dots.append(Dot(
                x: px,
                y: py,
                z: zr,
                r: (nodeR * 1.5 + nodeRDepth * depth) * rs,
                opacity: (0.5 + 0.5 * depth) * (1 - 0.05)
            ))
        }

        paintLines(context: context, lines: lines, color: color)
        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Shaping: morphing outline (port of engine/morph.ts, size-20 preset)

    /// Dotted outline cycling circle → triangle → square → circle.
    ///
    /// Upstream blends the two neighbouring shape *paths*, then lays dots
    /// evenly along the blended outline by arc length. Interpolating vertex
    /// positions directly would be simpler and wrong: spacing would bunch at
    /// the corners during the transition. Even spacing at every instant is
    /// the whole effect.
    private static func drawMorph(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 2.08, count ×0.53, radius ×1.011, spread 1.45.
        let t = time * 2.08
        let spread = 1.45
        let dotCount = max(6, Int((34.0 * 0.53).rounded()))
        let rDot = 0.021 * 1.35 * spread * 1.011

        let hold = 1.4
        let morphDuration = 0.9
        let segment = hold + morphDuration
        let shapeCount = 3

        let cycle = t.truncatingRemainder(dividingBy: segment * Double(shapeCount))
        let index = Int(cycle / segment)
        let local = cycle - Double(index) * segment
        // smoothstep, matching upstream's `smoothE`.
        let raw = local > hold ? (local - hold) / morphDuration : 0
        let m = raw * raw * (3 - 2 * raw)

        // Sample the two blended paths at a fixed resolution, then walk the
        // result by arc length. `M = 160` is upstream's value.
        let samples = 160
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(samples)
        for i in 0..<samples {
            let f = Double(i) / Double(samples)
            let a = morphPath(index, f)
            let b = morphPath((index + 1) % shapeCount, f)
            pts.append((
                (a.0 + (b.0 - a.0) * m) * spread,
                (a.1 + (b.1 - a.1) * m) * spread
            ))
        }

        var lengths: [Double] = []
        lengths.reserveCapacity(samples)
        var total = 0.0
        for i in 0..<samples {
            let a = pts[i]
            let b = pts[(i + 1) % samples]
            let l = ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
            lengths.append(l)
            total += l
        }

        let pulse = 1 + 0.02 * sin(local * 3.1)
        let centre = size / 2

        var dots: [Dot] = []
        dots.reserveCapacity(dotCount)
        var segIndex = 0
        var accumulated = 0.0
        for k in 0..<dotCount {
            let target = (Double(k) / Double(dotCount)) * total
            while segIndex < samples - 1, accumulated + lengths[segIndex] < target {
                accumulated += lengths[segIndex]
                segIndex += 1
            }
            let a = pts[segIndex]
            let b = pts[(segIndex + 1) % samples]
            let f = lengths[segIndex] > 0 ? min(1, (target - accumulated) / lengths[segIndex]) : 0
            let x = (a.0 + (b.0 - a.0) * f) * pulse
            let y = (a.1 + (b.1 - a.1) * f) * pulse
            dots.append(Dot(
                x: centre + x * size,
                y: centre + y * size,
                z: 0,
                r: max(0.35, rDot * size),
                // Upstream sets `white: 0.1`, i.e. near-solid ink, because it
                // paints through a threshold filter that hardens the edge.
                // We draw plain circles, so full-strength dots read heavier
                // here than every other orb — this is a flat outline with no
                // depth falloff to lighten it. Matching the depth-shaded
                // engines' mid-range keeps the family consistent.
                opacity: 0.62
            ))
        }

        paint(context: context, dots: dots, color: color)
    }

    /// The three closed paths of the morph cycle, parameterised by arc
    /// fraction from top-centre, clockwise. The square is walked as five
    /// vertices so its path *starts* at top-centre like the other two —
    /// otherwise the shapes rotate against each other as they blend.
    private static func morphPath(_ shape: Int, _ f: Double) -> (Double, Double) {
        switch shape {
        case 0:
            let a = -Double.pi / 2 + f * 2 * .pi
            return (cos(a) * 0.24, sin(a) * 0.24)
        case 1:
            return polyPath([(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)], f)
        default:
            return polyPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)], f)
        }
    }

    /// Walks a closed polygon by arc-length fraction.
    private static func polyPath(_ verts: [(Double, Double)], _ f: Double) -> (Double, Double) {
        let count = verts.count
        var lengths: [Double] = []
        lengths.reserveCapacity(count)
        var total = 0.0
        for i in 0..<count {
            let a = verts[i]
            let b = verts[(i + 1) % count]
            let l = ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
            lengths.append(l)
            total += l
        }
        var target = f * total
        var i = 0
        while i < count - 1, target > lengths[i] {
            target -= lengths[i]
            i += 1
        }
        let a = verts[i]
        let b = verts[(i + 1) % count]
        let ff = lengths[i] > 0 ? min(1, target / lengths[i]) : 0
        return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
    }

    // MARK: - Solving: twisting bands (port of engine/lattice.ts drawRubik, size-20 preset)

    /// A dot sphere whose bands twist in quarter turns, scramble, then replay
    /// in reverse so everything clicks back to solved before resting and
    /// repeating. The palindrome is the point: it reads as work that
    /// converges, which is why it maps to tests and builds.
    private static func drawRubik(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 1.95, count ×0.088 (√-split), radius ×1.9.
        let t = time * 1.95
        let latRings = 5      // round(15 × √0.088)
        let lonDensity = 12.0 // round(40 × √0.088)
        let rBase = 0.6 * 1.9
        let rDepth = 1.7 * 1.9
        let rActive = 0.3 * 1.9
        let inkFar = 0.62
        let inkSpan = 0.54
        let moveCount = 14

        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let pt = makeProj(
            yaw: t * 0.55,
            tilt: 0.35 + 0.1 * sin(t * 0.9),
            cx: cx,
            cy: cy,
            scale: radius
        )
        let rs = radiusScale(size: size, pow: 0.6)

        // Deterministic move list — same hash upstream uses, so the sequence
        // is stable across frames and launches.
        var moves: [(axis: Int, lo: Double, hi: Double, ang: Double)] = []
        moves.reserveCapacity(moveCount)
        for i in 0..<moveCount {
            let axis = min(2, Int(hashD(Double(i), 2.3) * 3))
            let lo = -1.0 + 0.5 * Double(min(3, Int(hashD(Double(i), 5.9) * 4)))
            let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
            moves.append((axis, lo, lo + 0.5, dir * .pi / 2))
        }

        // Scramble forward, then unwind: slot < count winds a band in,
        // slot >= count unwinds the mirrored one.
        let slotDuration = 0.42
        let rest = 1.2
        let cycleLength = 2 * Double(moveCount) * slotDuration + rest
        let tc = t.truncatingRemainder(dividingBy: cycleLength)
        var amount = [Double](repeating: 0, count: moveCount)
        var activeMove = -1
        if tc < 2 * Double(moveCount) * slotDuration {
            let slot = Int(tc / slotDuration)
            let p = (tc - Double(slot) * slotDuration) / slotDuration
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3) // machine ease-out
            if slot < moveCount {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                activeMove = slot
            } else {
                let u = 2 * moveCount - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                activeMove = u
            }
        }

        var dots: [Dot] = []
        dots.reserveCapacity((latRings + 1) * Int(lonDensity))

        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                var x = cosLat * cos(lon)
                var y = sinLat
                var z = cosLat * sin(lon)
                var inActive = false

                for i in 0..<moveCount where amount[i] > 0 {
                    let mv = moves[i]
                    let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
                    guard coord >= mv.lo, coord < mv.hi else { continue }
                    if i == activeMove { inActive = true }
                    let a = mv.ang * amount[i]
                    let ca = cos(a)
                    let sa = sin(a)
                    if mv.axis == 0 {
                        let y2 = y * ca - z * sa
                        z = y * sa + z * ca
                        y = y2
                    } else if mv.axis == 1 {
                        let x2 = x * ca + z * sa
                        z = -x * sa + z * ca
                        x = x2
                    } else {
                        let x2 = x * ca - y * sa
                        y = x * sa + y * ca
                        x = x2
                    }
                }

                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                // The band being turned inks a touch darker — the "hand".
                let white = inkFar - inkSpan * depth - (inActive ? 0.14 : 0)
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: zr,
                    r: (rBase + rDepth * depth + (inActive ? rActive : 0)) * rs,
                    opacity: 1 - white
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }

    // MARK: - Listening: rolling waveform (port of engine/lattice.ts drawWave, size-20 preset)

    /// A waveform rolls through the sphere's rings. Two sine terms at
    /// different tempi so it never quite repeats — it reads as attentive
    /// rather than mechanical, which is what "waiting on you" should feel
    /// like.
    private static func drawWave(
        context: GraphicsContext,
        size: Double,
        time: Double,
        color: Color
    ) {
        // Size-20 preset: speed 3.998, count ×0.105 (√-split), radius ×1.6.
        let t = time * 3.998
        let rings = 6         // round(15 × √0.105)
        let lonDensity = 13.0 // round(40 × √0.105)
        let rBase = 0.6 * 1.6
        let rDepth = 1.7 * 1.6

        let cx = size / 2
        let cy = size / 2
        // 0.76 base × 1.15: the undulation pulls the sphere inward, so wave
        // reads ~15% smaller than the other lattice modes without this.
        let radius = (size / 2) * 0.874
        // Scale 1 here on purpose — the radius is folded into the vectors
        // below so the wave can modulate it per ring.
        let pt = makeProj(yaw: t * 0.18, tilt: 0.38, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size: size, pow: 0.6)

        var dots: [Dot] = []
        dots.reserveCapacity((rings + 1) * Int(lonDensity))

        for ri in 0...rings {
            let lat = -Double.pi / 2 + (Double(ri) / Double(rings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            // Two waves, different tempi — organic, never quite repeating.
            let w = 0.62 * sin(t * 2.1 - Double(ri) * 0.52)
                + 0.38 * sin(t * 1.27 + Double(ri) * 0.83)
            let rr = radius * (0.88 + 0.105 * w)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(
                    cosLat * cos(lon) * rr,
                    sinLat * rr,
                    cosLat * sin(lon) * rr
                )
                let depth = (z / radius + 1) / 2
                let crest = max(0, w)
                let white = 0.66 - 0.56 * depth - 0.1 * crest
                dots.append(Dot(
                    x: px,
                    y: py,
                    z: z,
                    r: (rBase + rDepth * depth) * (1 + 0.4 * crest) * rs,
                    opacity: 1 - white
                ))
            }
        }

        paint(context: context, dots: dots, color: color)
    }
}

#Preview("Thinking orb states") {
    HStack(spacing: 24) {
        VStack(spacing: 8) {
            ThinkingOrbView(state: .thinking, size: 22)
            Text("thinking").font(.caption2)
        }
        VStack(spacing: 8) {
            ThinkingOrbView(state: .working, size: 22)
            Text("working").font(.caption2)
        }
        VStack(spacing: 8) {
            ThinkingOrbView(state: .searching, size: 22)
            Text("searching").font(.caption2)
        }
        VStack(spacing: 8) {
            ThinkingOrbView(state: .writing, size: 22)
            Text("writing").font(.caption2)
        }
        VStack(spacing: 8) {
            ThinkingOrbView(state: .connecting, size: 22)
            Text("connecting").font(.caption2)
        }
    }
    .padding()
}
