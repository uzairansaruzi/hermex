import SwiftUI

// The Thinking slider's looks built from paths rather than particles. All of them share one clock:
// `ThinkingSliderLook.advancePhase`, which stands still at the bottom of the ladder.

extension ThinkingSliderLook {
    /// Moves the shared clock, and returns the level the look should draw at.
    private static func advancePhase(_ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) -> Double {
        let active = frame.level < 0.002 ? 0 : frame.level
        if active > 0 { store.phase += frame.delta * (0.12 + 2.8 * active * active) }
        return active
    }

    /// `dashPhase` for a dash pattern that runs rightward at `offset`.
    private static func dashPhase(_ offset: Double, period: Double) -> CGFloat {
        let wrapped = offset.truncatingRemainder(dividingBy: period)
        return period - wrapped
    }

    private static func wave(from start: Double, to end: Double, step: Double, _ y: (Double) -> Double) -> Path {
        var path = Path(), x = start
        path.move(to: CGPoint(x: x, y: y(x)))
        while x <= end {
            x += step
            path.addLine(to: CGPoint(x: x, y: y(x)))
        }
        return path
    }

    /// Silk ribbons accelerate rightward, gaining layers and wider bends.
    static func drawSilk(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        var wash = context
        wash.opacity = 0.25 + active * 0.65
        wash.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .linearGradient(
            Gradient(colors: [Color(thinkingHex: 0x101D29), Color(thinkingHex: 0x182C43)]),
            startPoint: .zero, endPoint: CGPoint(x: width, y: 0)
        ))
        let ribbons = 3 + Int(active * 10)
        for index in 0..<ribbons {
            let lane = (Double(index) + 0.5) / Double(ribbons), baseline = 7 + lane * (height - 14)
            let path = wave(from: -4, to: width + 4, step: 4) { x in
                let unit = x / width
                let amplitude = (1 + active * 5) * sin(.pi * unit)
                return baseline + amplitude * sin(unit * (9 + active * 8) - store.phase * 4 + lane * 5)
            }
            let isBright = index % 3 == 0
            context.stroke(
                path,
                with: .color(Color(thinkingHex: isBright ? 0xAADBEA : 0x527DBA, opacity: (0.12 + active * 0.52) * (0.65 + lane * 0.35))),
                lineWidth: isBright ? 1.5 : 0.8
            )
            guard active > 0 else { continue }
            let run = 9 + active * 20, gap = 65 - active * 35
            context.stroke(path, with: .color(Color(thinkingHex: 0xE5F5FF, opacity: active * 0.65)), style: StrokeStyle(
                lineWidth: 1.5, dash: [run, gap], dashPhase: dashPhase(store.phase * (45 + lane * 16), period: run + gap)
            ))
        }
    }

    /// Broad copper vanes march rightward and pack together toward the top of the ladder.
    static func drawVectorDrive(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let gap = 67 - active * 43, shift = (store.phase * 37).truncatingRemainder(dividingBy: gap), thickness = 7 + active * 8
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: Color(thinkingHex: 0x77503D), location: 0),
                .init(color: Color(thinkingHex: 0xE5A678), location: 0.5),
                .init(color: Color(thinkingHex: 0x694137), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
        )
        var vanes = Path(), edges = Path()
        var x = -gap * 2 + shift
        while x < width + gap {
            vanes.move(to: CGPoint(x: x, y: 4))
            vanes.addLine(to: CGPoint(x: x + thickness, y: 4))
            vanes.addLine(to: CGPoint(x: x + thickness + 16, y: height / 2))
            vanes.addLine(to: CGPoint(x: x + thickness, y: height - 4))
            vanes.addLine(to: CGPoint(x: x, y: height - 4))
            vanes.addLine(to: CGPoint(x: x + 16, y: height / 2))
            vanes.closeSubpath()
            edges.move(to: CGPoint(x: x + thickness, y: 4))
            edges.addLine(to: CGPoint(x: x + thickness + 16, y: height / 2))
            edges.addLine(to: CGPoint(x: x + thickness, y: height - 4))
            x += gap
        }
        var fill = context
        fill.opacity = 0.07 + active * 0.62
        fill.fill(vanes, with: shading)
        context.stroke(edges, with: .color(Color(thinkingHex: 0xFFD9B5, opacity: 0.1 + active * 0.65)), lineWidth: 1)
        context.fill(
            Path(CGRect(x: 0, y: height / 2 - 0.5, width: width, height: 1)),
            with: .color(Color(thinkingHex: 0xFFF1DA, opacity: active * 0.25))
        )
    }

    static func drawVectorThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let x = frame.thumbX, y = frame.height / 2
        let body = Path(roundedRect: CGRect(x: x - 13, y: y - 22, width: 26, height: 44), cornerRadius: 10)
        context.fill(body, with: .color(Color(thinkingHex: 0x241F1B)))
        context.stroke(body, with: .color(Color(thinkingHex: 0xEEC5A3)), lineWidth: 1.5)
        var grip = Path()
        for offset in [-3.0, 3.0] {
            grip.move(to: CGPoint(x: x + offset, y: y - 7))
            grip.addLine(to: CGPoint(x: x + offset, y: y + 7))
        }
        context.stroke(grip, with: .color(Color(thinkingHex: 0xFFF0DF)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// Wide elliptical wavefronts get closer, brighter and faster, like pressure building.
    static func drawPressureWave(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let gap = 104 - active * 82, shift = (store.phase * 39).truncatingRemainder(dividingBy: gap)
        var wash = context
        wash.opacity = active * 0.6
        wash.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .linearGradient(
            Gradient(colors: [Color(thinkingHex: 0x102020), Color(thinkingHex: 0x17423D)]),
            startPoint: .zero, endPoint: CGPoint(x: width, y: 0)
        ))
        let radiusX = 9 + active * 7, radiusY = height * 0.66
        var x = -gap * 2 + shift
        while x < width + gap {
            let unit = min(max(x / width, 0), 1)
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radiusX, y: height / 2 - radiusY, width: radiusX * 2, height: radiusY * 2)),
                with: .color(Color(thinkingHex: 0x88D4BF, opacity: 0.07 + active * (0.18 + unit * 0.5))),
                lineWidth: 1 + active
            )
            if active > 0.4 {
                var crest = Path()
                crest.addArc(
                    center: .zero, radius: 1, startAngle: .radians(-1.3), endAngle: .radians(1.3), clockwise: false,
                    transform: CGAffineTransform(translationX: x + 3, y: height / 2).scaledBy(x: radiusX, y: radiusY)
                )
                context.stroke(crest, with: .color(Color(thinkingHex: 0xD9FFDC, opacity: active * 0.65)), lineWidth: 1)
            }
            x += gap
        }
    }

    static func drawPressureThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let x = frame.thumbX, y = frame.height / 2
        func circle(_ radius: Double) -> Path {
            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        context.fill(circle(20), with: .color(Color(thinkingHex: 0x18312D)))
        context.stroke(circle(20), with: .color(Color(thinkingHex: 0xBCE4D1)), lineWidth: 1.5)
        context.stroke(circle(14), with: .color(Color(thinkingHex: 0x668F80)), lineWidth: 1)
        context.fill(circle(4), with: .color(Color(thinkingHex: 0xE7FFF1)))
    }

    /// Braided coils tighten into a dense traveling helix.
    static func drawInduction(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let turns = 1.2 + active * 4.8, coils = 2 + Int(active * 5)
        for coil in 0..<coils {
            let offset = Double(coil) * .pi * 2 / Double(coils)
            for side in 0..<2 {
                let path = wave(from: 0, to: width + 3, step: 3) { x in
                    let angle = x / width * .pi * 2 * turns - store.phase * 3 + offset
                    return height / 2 + sin(angle + Double(side) * .pi) * (5 + active * 16)
                }
                context.stroke(
                    path,
                    with: .color(Color(thinkingHex: side == 1 ? 0x9F8EDC : 0xD8D1FF, opacity: 0.07 + active * (side == 1 ? 0.26 : 0.53))),
                    lineWidth: side == 1 ? 1 : 1.5
                )
            }
        }
        context.fill(
            Path(CGRect(x: 0, y: height / 2 - 0.5, width: width, height: 1)),
            with: .color(Color(thinkingHex: 0xC6BFFF, opacity: 0.07 + active * 0.15))
        )
    }

    /// Interlocking metallic facets slide rightward, sharpening into a dense weave.
    static func drawFoldedLight(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let step = 80 - active * 53, shift = (store.phase * 28).truncatingRemainder(dividingBy: step)
        let rows = active < 0.35 ? 2 : active < 0.7 ? 3 : 4
        let rowHeight = height / Double(rows)
        for row in 0..<rows {
            var faces = Path(), lights = Path(), edges = Path()
            let middle = (Double(row) + 0.5) * rowHeight
            var x = -step * 2 + shift + Double(row % 2) * step / 2
            while x < width + step {
                let left = CGPoint(x: x, y: middle), peak = CGPoint(x: x + step / 2, y: middle - rowHeight / 2)
                let right = CGPoint(x: x + step, y: middle), foot = CGPoint(x: x + step / 2, y: middle + rowHeight / 2)
                faces.move(to: left); faces.addLine(to: peak); faces.addLine(to: right); faces.addLine(to: foot); faces.closeSubpath()
                lights.move(to: left); lights.addLine(to: peak); lights.addLine(to: right); lights.closeSubpath()
                edges.move(to: left); edges.addLine(to: peak)
                x += step
            }
            context.fill(faces, with: .color(Color(thinkingHex: row % 2 == 1 ? 0x507780 : 0x709099, opacity: 0.06 + active * 0.44)))
            context.fill(lights, with: .color(Color(thinkingHex: 0xC5E8E2, opacity: 0.03 + active * 0.46)))
            context.stroke(edges, with: .color(Color(thinkingHex: 0xE0FFF2, opacity: 0.06 + active * 0.6)), lineWidth: 0.75)
        }
    }

    static func drawFoldedThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let x = frame.thumbX, y = frame.height / 2
        let body = Path(roundedRect: CGRect(x: x - 17, y: y - 20, width: 34, height: 40), cornerRadius: 8)
        context.fill(body, with: .color(Color(thinkingHex: 0xD9E6E2)))
        context.stroke(body, with: .color(.white), lineWidth: 1)
        var shade = context
        shade.clip(to: body)
        shade.fill(Path(CGRect(x: x - 17, y: y, width: 34, height: 20)), with: .color(Color(thinkingHex: 0x8BA4A0)))
        context.fill(Path(CGRect(x: x - 5, y: y - 1, width: 10, height: 2)), with: .color(Color(thinkingHex: 0x45605D)))
    }

    /// Signals take angular routes through a circuit, lighting more lanes and moving faster.
    static func drawRelay(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let lanes = 2 + Int(active * 6)
        for lane in 0..<lanes {
            let y = 6 + Double(lane) * (height - 12) / Double(max(1, lanes - 1))
            let jog = (lane % 2 == 1 ? -1.0 : 1.0) * (3 + active * 3)
            let elbow = width * (0.22 + Double(lane % 3) * 0.15)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: elbow, y: y))
            path.addLine(to: CGPoint(x: elbow + 12, y: y + jog))
            path.addLine(to: CGPoint(x: width * 0.76, y: y + jog))
            path.addLine(to: CGPoint(x: width * 0.76 + 12, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            context.stroke(
                path, with: .color(Color(thinkingHex: 0x4F6A76, opacity: 0.14 + active * 0.2)),
                style: StrokeStyle(lineWidth: 1, lineJoin: .round)
            )
            if active > 0 {
                let run = 7 + active * 21, gap = 90 - active * 53
                context.stroke(
                    path,
                    with: .color(Color(thinkingHex: lane % 3 == 0 ? 0xFFCB78 : 0x89D5DC, opacity: 0.25 + active * 0.65)),
                    style: StrokeStyle(
                        lineWidth: 2, lineJoin: .round, dash: [run, gap],
                        dashPhase: dashPhase(store.phase * 52 + Double(lane) * 19, period: run + gap)
                    )
                )
            }
            context.fill(
                Path(CGRect(x: elbow - 1.5, y: y - 1.5, width: 3, height: 3)),
                with: .color(Color(thinkingHex: 0xE5D8A8, opacity: 0.12 + active * 0.35))
            )
        }
    }

    static func drawRelayThumb(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame) {
        let x = frame.thumbX, y = frame.height / 2
        let body = Path(roundedRect: CGRect(x: x - 18, y: y - 20, width: 36, height: 40), cornerRadius: 8)
        context.fill(body, with: .color(Color(thinkingHex: 0x202C32)))
        context.stroke(body, with: .color(Color(thinkingHex: 0xB1D6DD)), lineWidth: 1.5)
        context.fill(
            Path(roundedRect: CGRect(x: x - 8, y: y - 9, width: 16, height: 18), cornerRadius: 3),
            with: .color(Color(thinkingHex: 0xD7F4EF))
        )
        var pins = Path()
        for offset in stride(from: -10.0, through: 10, by: 5) {
            pins.move(to: CGPoint(x: x - 13, y: y + offset)); pins.addLine(to: CGPoint(x: x - 10, y: y + offset))
            pins.move(to: CGPoint(x: x + 10, y: y + offset)); pins.addLine(to: CGPoint(x: x + 13, y: y + offset))
        }
        context.stroke(pins, with: .color(Color(thinkingHex: 0xB1D6DD)), lineWidth: 1)
    }

    /// A silver-blue liquid rises from a quiet surface to a deep, fast current.
    static func drawLiquidCore(_ context: inout GraphicsContext, _ frame: ThinkingSliderFrame, _ store: ThinkingSliderStore) {
        let active = advancePhase(frame, store), width = frame.width, height = frame.height
        context.fillThinkingTrack(frame, 0x11151C)
        let top = height - 5 - active * (height - 13)
        let layers = 2 + Int(active * 4)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: Color(thinkingHex: 0xAAC4DF), location: 0),
                .init(color: Color(thinkingHex: 0x597FBA), location: 0.35),
                .init(color: Color(thinkingHex: 0x203951), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
        )
        func surface(_ layer: Int) -> Path {
            let depth = Double(layer)
            return wave(from: -4, to: width + 4, step: 4) { x in
                let unit = x / width
                let baseline = top + depth * (3 + active * 3)
                let amplitude = active * (2 + depth * 0.6)
                let phase = unit * (12 + active * 13) - store.phase * (3 + depth * 0.13) + depth * 0.85
                return baseline + amplitude * sin(phase)
            }
        }
        for layer in stride(from: layers - 1, through: 0, by: -1) {
            var body = surface(layer)
            body.addLine(to: CGPoint(x: width + 4, y: height))
            body.addLine(to: CGPoint(x: -4, y: height))
            body.closeSubpath()
            var fill = context
            fill.opacity = layer == 0 ? 0.25 + active * 0.5 : 0.15
            fill.fill(body, with: shading)
        }
        for layer in 0..<layers {
            context.stroke(
                surface(layer),
                with: .color(Color(thinkingHex: 0xC8E2FF, opacity: (0.1 + active * 0.65) / (1 + Double(layer) * 0.5))),
                lineWidth: layer == 0 ? 1.5 : 0.75
            )
        }
    }
}
