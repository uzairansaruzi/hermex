import CoreGraphics
// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import SwiftUI

/// Shared by the off-main bitmap renderer and the clockless live Canvas.
nonisolated enum BotAvatarDrawing {
    static func eyePath(_ mark: BotAvatarEyeMark) -> CGPath {
        let p = CGMutablePath()
        let w = mark.width
        let h = mark.height
        if mark.happy {
            p.move(to: CGPoint(x: -0.72 * w, y: 0.1 * h))
            p.addQuadCurve(to: CGPoint(x: 0.72 * w, y: 0.1 * h), control: CGPoint(x: 0, y: -0.42 * h))
        } else {
            let r = min(w, h) / 2
            p.addRoundedRect(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r)
        }
        let angle = mark.tilt * .pi / 180
        var transform = CGAffineTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: mark.x, ty: mark.y)
        return p.copy(using: &transform)!
    }
    static func color(_ rgb: BotAvatarRGB) -> CGColor {
        CGColor(
            red: BotAvatarPose.clamp(rgb.r, 0, 255) / 255, green: BotAvatarPose.clamp(rgb.g, 0, 255) / 255,
            blue: BotAvatarPose.clamp(rgb.b, 0, 255) / 255, alpha: 1)
    }
    static func slice(_ shape: BotAvatarFrame.Shape, volume: BotAvatarVolume) -> BotAvatarSlice? {
        guard case .slice(let part, let index, let side) = shape else { return nil }
        return side ? volume.parts[part].xSlices[index] : volume.parts[part].zSlices[index]
    }
    static func paintEye(_ mark: BotAvatarEyeMark, in context: CGContext) {
        context.addPath(eyePath(mark))
        if mark.happy {
            context.setLineWidth(mark.width * 0.6)
            context.setLineCap(.round)
            context.strokePath()
        } else {
            context.fillPath()
        }
    }
    static func draw(frame: BotAvatarFrame, volume: BotAvatarVolume, context: CGContext, body: BotAvatarRGB, ink: BotAvatarRGB) {
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(frame.root.affine)
        for item in frame.shapes {
            context.saveGState()
            context.concatenate(item.matrix.affine)
            if let slice = slice(item.shape, volume: volume) {
                context.setFillColor(color(body))
                context.addPath(slice.path)
                context.drawPath(using: slice.evenOdd ? .eoFill : .fill)
            } else if case .eye(let mark) = item.shape {
                context.setFillColor(color(ink))
                context.setStrokeColor(color(ink))
                paintEye(mark, in: context)
            }
            context.restoreGState()
        }
    }
    static func draw(frame: BotAvatarFrame, volume: BotAvatarVolume, context: inout GraphicsContext, body: Color, ink: Color) {
        context.concatenate(frame.root.affine)
        for item in frame.shapes {
            var layer = context
            layer.concatenate(item.matrix.affine)
            if let slice = slice(item.shape, volume: volume) {
                layer.fill(Path(slice.path), with: .color(body), style: FillStyle(eoFill: slice.evenOdd))
            } else if case .eye(let mark) = item.shape {
                drawEye(mark, context: &layer, color: ink)
            }
        }
    }
    static func drawEye(_ mark: BotAvatarEyeMark, context: inout GraphicsContext, color: Color) {
        let path = Path(eyePath(mark))
        if mark.happy {
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: mark.width * 0.6, lineCap: .round))
        } else {
            context.fill(path, with: .color(color))
        }
    }
}

/// Build with the volume off-main. Flat paths and eye transforms are retained through every blink.
nonisolated struct BotAvatarRestDrawing: Sendable {
    struct EyePlane: Sendable {
        let index: Int
        let matrix: AvatarMatrix
    }
    let volume: BotAvatarVolume
    let frame: BotAvatarFrame
    let flatPaths: [Path]
    let eyePlanes: [EyePlane]
    let splitIndex: Int
    init(volume: BotAvatarVolume) {
        self.volume = volume
        let frame = BotAvatarFrame.make(volume: volume)
        self.frame = frame
        splitIndex =
            frame.shapes.firstIndex {
                if case .eye = $0.shape { return true }
                return false
            } ?? frame.shapes.count
        eyePlanes = frame.shapes.compactMap {
            guard case .eye(let mark) = $0.shape else { return nil }
            return EyePlane(index: mark.index, matrix: frame.root.times($0.matrix))
        }
        if volume.depth == 0 {
            flatPaths = frame.shapes.compactMap { item in
                guard let slice = BotAvatarDrawing.slice(item.shape, volume: volume) else { return nil }
                return Path(slice.path).applying(frame.root.times(item.matrix).affine)
            }
        } else {
            flatPaths = []
        }
    }
}

/// Clockless live tier. The owning view supplies finite pose updates only while movement is active.
struct BotAvatarLiveView: View {
    let volume: BotAvatarVolume
    var pose: BotAvatarPose = .rest
    var layout: BotAvatarEyeLayout? = nil
    var bodyColor: Color = .orange
    var eyeColor: Color = .black
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            let shown = reduceMotion ? BotAvatarPose.rest : pose
            let frame = BotAvatarFrame.make(volume: volume, pose: shown, layout: layout)
            BotAvatarDrawing.draw(frame: frame, volume: volume, context: &context, body: bodyColor, ink: eyeColor)
        }
        .accessibilityHidden(true)
    }
}

/// Keep this view separate from the body tier so a blink only invalidates the two eye marks.
struct BotAvatarEyeLayer: View {
    let rest: BotAvatarRestDrawing
    let layout: BotAvatarEyeLayout
    var lid: Double = 1
    /// Normalized gaze, clamped to the range reserved when fitting the eyes.
    var gaze: AvatarPoint = AvatarPoint(0, 0)
    var color: Color = .black
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            let offset = AvatarPoint(
                BotAvatarPose.clamp(gaze.x, -1, 1) * 1.5 * rest.volume.eyeScale,
                BotAvatarPose.clamp(gaze.y, -1, 1) * 1.1 * rest.volume.eyeScale)
            let marks = layout.marks(eyes: rest.volume.definition.eyes, lid: lid, gaze: offset)
            for plane in rest.eyePlanes {
                guard let mark = marks.first(where: { $0.index == plane.index }) else { continue }
                var layer = context
                layer.concatenate(plane.matrix.affine)
                BotAvatarDrawing.drawEye(mark, context: &layer, color: color)
            }
        }
        .accessibilityHidden(true)
    }
}
