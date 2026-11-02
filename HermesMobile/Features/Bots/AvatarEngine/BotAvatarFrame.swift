import CoreGraphics
// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

nonisolated struct AvatarMatrix: Sendable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    var values: [Double] { [a, b, c, d, tx, ty] }
    var affine: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    func times(_ n: Self) -> Self {
        Self(
            a: a * n.a + c * n.b, b: b * n.a + d * n.b, c: a * n.c + c * n.d, d: b * n.c + d * n.d,
            tx: a * n.tx + c * n.ty + tx, ty: b * n.tx + d * n.ty + ty)
    }
    static func translation(_ x: Double, _ y: Double) -> Self { Self(tx: x, ty: y) }
}
nonisolated struct AvatarViewBasis {
    let cy: Double, sy: Double, cp: Double, sp: Double
    init(_ pose: BotAvatarPose) {
        cy = cos(pose.yaw)
        sy = sin(pose.yaw)
        cp = cos(pose.pitch)
        sp = sin(pose.pitch)
    }
    var side: Bool { abs(cy) < abs(sy) }
    func facing(_ n: AvatarVector3) -> Double { sp * n.y + cp * (-sy * n.x + cy * n.z) }
    func plane(_ z: Double, _ p: AvatarPoint) -> AvatarMatrix {
        .init(a: cy, b: sy * sp, c: 0, d: cp, tx: p.x - cy * p.x + sy * z, ty: p.y - cp * p.y - sy * sp * p.x - cy * sp * z)
    }
    func sidePlane(_ x: Double, _ p: AvatarPoint) -> AvatarMatrix {
        .init(a: -sy, b: cy * sp, c: 0, d: cp, tx: p.x + cy * (x - p.x), ty: p.y - cp * p.y + sy * sp * (x - p.x))
    }
    func depth(_ x: Double, _ y: Double, _ z: Double, _ pivot: AvatarPoint) -> Double {
        sp * (y - pivot.y) + cp * (-sy * (x - pivot.x) + cy * z)
    }
}
nonisolated struct BotAvatarEyeMark: Sendable {
    let index: Int
    var x: Double, y: Double, width: Double, height: Double
    var happy: Bool
    var tilt = 0.0
}
nonisolated struct BotAvatarFrame: Sendable {
    enum Shape: Sendable {
        case slice(part: Int, index: Int, side: Bool)
        case eye(BotAvatarEyeMark)
    }
    struct Item: Sendable {
        let shape: Shape
        let matrix: AvatarMatrix
        let depth: Double
    }
    let root: AvatarMatrix
    let shapes: [Item]
    /// Pure evaluation, using only prepared geometry. Caller supplies one pose, including blink closure.
    static func make(volume v: BotAvatarVolume, pose: BotAvatarPose = .rest, layout: BotAvatarEyeLayout? = nil) -> Self {
        let basis = AvatarViewBasis(pose)
        let pivot = v.body.bounds.center
        let eyes = v.definition.eyes
        let sweep = hypot(basis.sy, basis.cy * basis.sp)
        let inset = min(abs(basis.cy), abs(basis.cp))
        var items: [Item] = []
        items.reserveCapacity(128)
        for (i, part) in v.parts.enumerated() {
            let ref = i == v.eyePart ? AvatarPoint(eyes.x, eyes.y) : part.bounds.center
            for (j, slice) in (basis.side ? part.xSlices : part.zSlices).enumerated() {
                if !basis.side && slice.inset > 0 && abs(slice.at) * sweep <= slice.inset * inset { continue }
                let matrix = basis.side ? basis.sidePlane(slice.at, pivot) : basis.plane(slice.at, pivot)
                let depth = basis.side ? basis.depth(slice.at, ref.y, 0, pivot) : basis.depth(ref.x, ref.y, slice.at, pivot)
                items.append(Item(shape: .slice(part: i, index: j, side: basis.side), matrix: matrix, depth: depth))
            }
        }
        let s = v.eyeScale
        let w = 4 * s
        let h = 11 * s
        let r = v.gazeRange
        let dx = pose.gazeX * (pose.gazeX >= 0 ? r[1] : r[0]) * 1.5 * s
        let dy = pose.gazeY * (pose.gazeY >= 0 ? r[3] : r[2]) * 1.1 * s
        let fitted = layout?.marks(eyes: eyes, lid: 1 - pose.blink, gaze: AvatarPoint(dx, dy))
        for (i, c) in eyes.centers.enumerated() where v.eyeNormals[i].allSatisfy({ basis.facing($0) > 0.22 }) {
            if layout != nil && fitted?.isEmpty == true { continue }
            let squint = i == 0 ? pose.squintL : pose.squintR
            let open = max(h * max(0.09, (1 - pose.blink) * (1 - squint * 0.4)), w * 0.55)
            let z = v.eyeZ[i] + 1.5
            let mark =
                fitted?.first(where: { $0.index == i })
                ?? BotAvatarEyeMark(
                    index: i, x: c.x + dx, y: c.y + dy + (pose.happy ? 0 : (h - open) * 0.18), width: w, height: pose.happy ? h : open,
                    happy: pose.happy)
            items.append(Item(shape: .eye(mark), matrix: basis.plane(z, pivot), depth: basis.depth(eyes.x, eyes.y, z, pivot) + 1e-6))
        }
        // Swift's stable sort preserves upstream insertion order for equal depths.
        items.sort { $0.depth < $1.depth }
        let rads = pose.roll * .pi / 180
        let bx = pivot.x
        let by = v.body.bounds.maxY
        let rot = AvatarMatrix(a: cos(rads), b: sin(rads), c: -sin(rads), d: cos(rads))
        let root = AvatarMatrix.translation(0, pose.lift).times(.translation(bx, by))
            .times(rot).times(AvatarMatrix(a: pose.sx, d: pose.sy)).times(.translation(-bx, -by))
        return Self(root: root, shapes: items)
    }
}
