import CoreGraphics
// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

/// Paths are immutable copies, built once and safely shared between renderers.
nonisolated struct BotAvatarSlice: @unchecked Sendable {
    let path: CGPath
    let loops: [[AvatarPoint]]
    let at: Double
    let evenOdd: Bool
    let inset: Double
    let side: Bool
}
nonisolated struct AvatarRevolveProfile: Sendable {
    let start: Double
    let radii: [Double]
    func radius(_ s: Double) -> Double {
        let t = (s - start) / 0.2
        if t < 0 || t > Double(radii.count - 1) { return 0 }
        let k = min(radii.count - 2, Int(floor(t)))
        return radii[k] + (radii[k + 1] - radii[k]) * (t - Double(k))
    }
    static func make(_ polys: [[AvatarPoint]], rows: Bool, lo: Double, hi: Double, center: Double) -> Self? {
        let n = max(2, Int(ceil((hi - lo) / 0.2)) + 1)
        var r = [Double](repeating: 0, count: n)
        var mids: [Double] = []
        var span = 0.0
        for k in 0..<n {
            let s = min(hi - 0.01, max(lo + 0.01, lo + Double(k) * 0.2))
            let xs = AvatarGeometry.crossings(polys, at: s, rows: rows).map(\.0)
            if xs.isEmpty { continue }
            if xs.count != 2 { return nil }
            r[k] = (xs[1] - xs[0]) / 2
            span = max(span, xs[1] - xs[0])
            mids.append((xs[0] + xs[1]) / 2)
        }
        if mids.isEmpty || mids.contains(where: { abs($0 - center) > max(0.8, 0.04 * span) }) { return nil }
        return Self(start: lo, radii: r)
    }
}
nonisolated struct BotAvatarPart: Sendable {
    enum Kind: String, Sendable {
        case inflate
        case revolveX = "revolve-x"
        case revolveY = "revolve-y"
    }
    let kind: Kind
    let polys: [[AvatarPoint]]
    let bounds: AvatarBounds
    let thickness: Double, depth: Double, rxy: Double, rz: Double
    let axis: Double
    let profile: AvatarRevolveProfile?
    let factor: Double
    var zSlices: [BotAvatarSlice] = [], xSlices: [BotAvatarSlice] = []
    func surface(_ x: Double, _ y: Double, _ distance: Double) -> Double {
        if let profile {
            let radius = profile.radius(kind == .revolveX ? x : y)
            let offset = (kind == .revolveX ? y : x) - axis
            return factor * sqrt(max(0, radius * radius - offset * offset))
        }
        let half = depth / 2
        if rxy <= 0 || distance >= rxy { return half }
        let k = 1 - max(0, distance) / rxy
        return half - rz + sqrt(max(0, 1 - k * k)) * rz
    }
    func height(_ x: Double, _ y: Double) -> Double {
        guard AvatarGeometry.inside(polys, x, y) else { return 0 }
        return surface(x, y, kind == .inflate ? AvatarGeometry.edgeDistance(polys, AvatarPoint(x, y)) : 0)
    }
}

/// Prepare off-main once per geometry/depth. Frame evaluation never parses paths or samples fields.
nonisolated struct BotAvatarVolume: Sendable {
    let definition: BotAvatarDefinition
    let depth: Double
    let body: AvatarBodyAnalysis
    let parts: [BotAvatarPart]
    let eyePart: Int
    let eyeZ: [Double]
    let eyeScale: Double
    let eyeNormals: [[AvatarVector3]]
    let gazeRange: [Double]
    let seed: UInt32

    static func prepare(_ definition: BotAvatarDefinition, depth: Double = 6) throws -> Self {
        let def = try BotAvatarValidator.validate(definition).get()
        let d = AvatarPath.rounded(min(14, max(0, depth.isFinite ? depth : 6)), places: 2)
        let body = try AvatarBodyAnalysis(def.body.path)
        let factor = d / 6
        let outlines = body.subpaths.filter { !$0.hole }
        let holes = body.subpaths.filter(\.hole)
        let xAxis = horizontalAxis(body)
        var parts: [BotAvatarPart] = []
        for outline in outlines {
            let cuts = holes.filter { h in h.probe.map { AvatarGeometry.inside(outline.polys, $0.x, $0.y) } ?? false }
            let polys = outline.polys + cuts.flatMap(\.polys)
            let b = AvatarBounds(outline.polys)
            let step = max(0.25, min(0.45, min(b.width, b.height) / 24))
            var kind = BotAvatarPart.Kind.inflate
            var profile: AvatarRevolveProfile?
            if let xAxis {
                profile = .make(polys, rows: false, lo: b.minX, hi: b.maxX, center: xAxis)
                if profile != nil { kind = .revolveX }
            } else if outlines.count > 1 && cuts.isEmpty {
                profile = .make(polys, rows: true, lo: b.minY, hi: b.maxY, center: b.center.x)
                if profile != nil { kind = .revolveY }
            }
            let thickness: Double
            let partDepth: Double
            let rxy: Double
            let rz: Double
            if let profile {
                thickness = 2 * (profile.radii.max() ?? 0)
                partDepth = thickness * factor
                rxy = 0
                rz = 0
            } else {
                let coarse = AvatarGrid(polys: polys, bounds: b, step: max(step, 0.6)) { _, _, _ in 0 }
                thickness = 2 * max(0, coarse.sd.max() ?? 0)
                let raw = 0.8 * max(thickness, min(0.4 * max(b.width, b.height), 2.4 * thickness))
                partDepth = min(30, max(3, raw)) * factor
                rxy = min(thickness / 2, partDepth / 2) * 0.9
                rz = partDepth / 2 * 0.85
            }
            var part = BotAvatarPart(
                kind: kind, polys: polys, bounds: b, thickness: thickness, depth: partDepth, rxy: rxy, rz: rz,
                axis: kind == .revolveX ? xAxis ?? 0 : b.center.x, profile: profile, factor: factor)
            let core = AvatarPath.cgPath(outline.segments + cuts.flatMap(\.segments))
            part.zSlices = [.init(path: core, loops: polys, at: 0, evenOdd: false, inset: 0, side: false)]
            let half = partDepth / 2
            if half > 0.05 {
                let shape = part
                let grid = AvatarGrid(polys: polys, bounds: b, step: step, height: shape.surface)
                let steps = kind == .inflate ? max(4, min(14, Int(floor(rz / 0.8 + 0.5)))) : max(5, min(18, Int(floor(half / 1.1 + 0.5))))
                let flat = kind == .inflate ? half - rz : 0
                let round = kind == .inflate ? rz : half
                let levels = (kind == .inflate ? [flat] : []) + (1..<steps).map { flat + round * sin(Double($0) / Double(steps) * .pi / 2) }
                func addLevel(_ level: Double, _ box: AvatarGrid.Box? = nil) -> Bool {
                    let loops = grid.levelLoops(level, box: box)
                    if loops.isEmpty { return false }
                    let samples = loops.flatMap { $0 }.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
                    let inset = samples.map { AvatarGeometry.edgeDistance(polys, $0) }.min() ?? 0
                    let path = AvatarPath.polygonPath(loops)
                    part.zSlices += [
                        BotAvatarSlice(path: path, loops: loops, at: level, evenOdd: true, inset: inset, side: false),
                        BotAvatarSlice(path: path, loops: loops, at: -level, evenOdd: true, inset: inset, side: false),
                    ]
                    return true
                }
                var used = [0.0]
                for level in levels where level >= 0.02 { if addLevel(level) { used.append(level) } }
                if kind == .inflate {
                    for box in grid.thinBoxes() {
                        for k in 1..<used.count where used[k - 1] < box.top {
                            let a = used[k - 1]
                            let gap = used[k] - a
                            let m = Int(ceil(gap / 0.6 - 1e-9))
                            if m > 1 {
                                for q in 1..<m where a + gap * Double(q) / Double(m) < box.top {
                                    _ = addLevel(a + gap * Double(q) / Double(m), box)
                                }
                            }
                        }
                    }
                }
                part.zSlices.sort { $0.at < $1.at }
                let every = max(1, Int(floor(max(1.1, b.width / 40) / grid.step + 0.5)))
                let before = (every - 1) / 2
                for i in stride(from: 1, to: grid.nx - 1, by: every) {
                    let loops = grid.columnLoops(max(0, i - before), min(grid.nx - 1, i - before + every - 1)) { shape.surface($0, $1, 0) }
                    if !loops.isEmpty {
                        part.xSlices.append(
                            .init(
                                path: AvatarPath.polygonPath(loops), loops: loops, at: grid.x0 + Double(i) * grid.step, evenOdd: true,
                                inset: 0, side: true))
                    }
                }
            }
            parts.append(part)
        }
        guard !parts.isEmpty else { throw AvatarPath.fail("body has no filled part") }
        let eyeScale = AvatarEyeFit.boost(body, def.eyes)
        let centers = def.eyes.centers
        var eyePart = 0
        var bestZ = -Double.infinity
        for (i, part) in parts.enumerated() {
            let zs = centers.map { part.height($0.x, $0.y) }
            if zs.contains(where: { $0 <= 0 }) { continue }
            if let z = zs.min(), z > bestZ {
                bestZ = z
                eyePart = i
            }
        }
        let host = parts[eyePart]
        let w = 3.5 * eyeScale
        let hh = 6.6 * eyeScale
        let eyeZ = centers.map { c in
            var top = 0.0
            for fx in [-1.0, -0.5, 0, 0.5, 1] {
                for fy in [-1.0, -0.5, 0, 0.5, 1] { top = max(top, host.height(c.x + fx * w, c.y + fy * hh)) }
            }
            return top
        }
        let normals = centers.map { c in
            [-2 * eyeScale, 0, 2 * eyeScale].map { dx -> AvatarVector3 in
                let x = c.x + dx
                let gx = (host.height(x + 0.75, c.y) - host.height(x - 0.75, c.y)) / 1.5
                let gy = (host.height(x, c.y + 0.75) - host.height(x, c.y - 0.75)) / 1.5
                let n = sqrt(gx * gx + gy * gy + 1)
                return AvatarVector3(x: -gx / n, y: -gy / n, z: 1 / n)
            }
        }
        var eyes = def.eyes
        eyes.scale = eyeScale
        return Self(
            definition: def, depth: d, body: body, parts: parts, eyePart: eyePart, eyeZ: eyeZ, eyeScale: eyeScale,
            eyeNormals: normals, gazeRange: AvatarEyeFit.range(body, eyes), seed: BotAvatarPose.hash(def.id))
    }
    private static func horizontalAxis(_ body: AvatarBodyAnalysis) -> Double? {
        let b = body.bounds
        let outlines = body.subpaths.filter { !$0.hole }
        let axis = b.center.y
        guard outlines.count >= 2, b.width >= 1.1 * b.height else { return nil }
        for o in outlines where abs(AvatarBounds(o.polys).center.y - axis) > 1.5 { return nil }
        let xs = Array(stride(from: b.minX + 0.5, to: b.maxX, by: 1))
        var filled = 0
        var off = 0
        for y in stride(from: b.minY + 0.5, to: axis, by: 1) {
            let top = AvatarGeometry.row(body.polys, y, xs)
            let bottom = AvatarGeometry.row(body.polys, 2 * axis - y, xs)
            for k in xs.indices {
                if top[k] || bottom[k] { filled += 1 }
                if top[k] != bottom[k] { off += 1 }
            }
        }
        return filled > 0 && Double(off) / Double(filled) < 0.02 ? axis : nil
    }
}
nonisolated struct AvatarVector3: Sendable {
    let x: Double
    let y: Double
    let z: Double
}
