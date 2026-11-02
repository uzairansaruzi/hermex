// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

nonisolated enum AvatarGeometry {
    static func crossings(_ polys: [[AvatarPoint]], at s: Double, rows: Bool = true) -> [(Double, Int)] {
        var hits: [(Double, Int)] = []
        for poly in polys where !poly.isEmpty {
            var p = poly[poly.count - 1]
            for q in poly {
                let ay = rows ? p.y : p.x, by = rows ? q.y : q.x
                let ax = rows ? p.x : p.y, bx = rows ? q.x : q.y
                if (ay <= s && by > s) || (by <= s && ay > s) { hits.append((ax + (s - ay) * (bx - ax) / (by - ay), by > ay ? 1 : -1)) }
                p = q
            }
        }
        return hits.sorted { $0.0 < $1.0 }
    }
    static func inside(_ polys: [[AvatarPoint]], _ x: Double, _ y: Double) -> Bool {
        var w = 0
        for poly in polys where !poly.isEmpty {
            var p = poly[poly.count - 1]
            for q in poly {
                let cross = (q.x - p.x) * (y - p.y) - (x - p.x) * (q.y - p.y)
                if p.y <= y { if q.y > y && cross > 0 { w += 1 } }
                else if q.y <= y && cross < 0 { w -= 1 }
                p = q
            }
        }
        return w != 0
    }
    static func row(_ polys: [[AvatarPoint]], _ y: Double, _ xs: [Double]) -> [Bool] {
        let hits = crossings(polys, at: y); var w = 0, h = 0
        return xs.map { x in
            while h < hits.count && hits[h].0 < x { w += hits[h].1; h += 1 }
            return w != 0
        }
    }
    static func area(_ polys: [[AvatarPoint]], _ b: AvatarBounds) -> Double {
        let xs = Array(stride(from: floor(b.minX) + 0.5, to: b.maxX, by: 1))
        return stride(from: floor(b.minY) + 0.5, to: b.maxY, by: 1).reduce(0) { sum, y in
            sum + Double(row(polys, y, xs).filter { $0 }.count)
        }
    }
    static func distance(_ p: AvatarPoint, _ a: AvatarPoint, _ b: AvatarPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
    }
    static func edgeDistance(_ polys: [[AvatarPoint]], _ p: AvatarPoint) -> Double {
        var best = Double.infinity
        for poly in polys where !poly.isEmpty {
            var a = poly[poly.count - 1]
            for b in poly { best = min(best, distance(p, a, b)); a = b }
        }
        return best
    }
}

nonisolated struct AvatarBodyAnalysis: Sendable {
    struct Subpath: Sendable {
        let segments: [AvatarSegment]
        let polys: [[AvatarPoint]]
        let hole: Bool
        let probe: AvatarPoint?
    }
    let segments: [AvatarSegment]
    let polys: [[AvatarPoint]]
    let bounds: AvatarBounds
    let area: Double
    let subpaths: [Subpath]
    init(_ path: String) throws {
        segments = try AvatarPath.parse(path)
        polys = AvatarPath.flatten(segments); bounds = AvatarBounds(polys)
        // Arc correction can enlarge an ellipse dramatically. Reject before scanning any grids.
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
              bounds.minX >= -200, bounds.minY >= -200, bounds.maxX <= 300, bounds.maxY <= 300 else {
            throw AvatarPath.fail("body.path has empty or excessive geometry")
        }
        area = AvatarGeometry.area(polys, bounds)
        var subs: [[AvatarSegment]] = []
        for s in segments {
            if s.command == "M" { subs.append([]) }
            if !subs.isEmpty { subs[subs.count - 1].append(s) }
        }
        var result: [Subpath] = []
        for sub in subs {
            let own = AvatarPath.flatten(sub)
            if own.isEmpty { continue }
            let b = AvatarBounds(own), alone = own.count == polys.count
            let step = b.width * b.height < 900 ? 0.5 : 1.0
            let xs = Array(stride(from: floor(b.minX) + step / 2, to: b.maxX, by: step))
            var count = 0, cut = 0, probe: AvatarPoint?, cutProbe: AvatarPoint?
            for y in stride(from: floor(b.minY) + step / 2, to: b.maxY, by: step) {
                let mine = AvatarGeometry.row(own, y, xs), all = alone ? mine : AvatarGeometry.row(polys, y, xs)
                for k in xs.indices where mine[k] {
                    count += 1; if probe == nil { probe = AvatarPoint(xs[k], y) }
                    if !alone && !all[k] { cut += 1; if cutProbe == nil { cutProbe = AvatarPoint(xs[k], y) } }
                }
            }
            let hole = count > 0 && Double(cut) / Double(count) > 0.6
            result.append(Subpath(segments: sub, polys: own, hole: hole, probe: hole ? cutProbe : probe))
        }
        subpaths = result
    }
}

nonisolated enum AvatarSeams {
    struct Seam: Sendable { let side: String; let at: Double; let size: Double }
    /// Advisory silhouette joins, independent of import validity.
    static func find(_ polys: [[AvatarPoint]]) -> [Seam] {
        let b = AvatarBounds(polys)
        guard b.minX.isFinite else { return [] }
        var result: [Seam] = []
        for (side, rows, low) in [("left", true, true), ("right", true, false), ("top", false, true), ("bottom", false, false)] {
            var at: [Double] = [], e: [Double] = []
            for s in stride(from: (rows ? b.minY : b.minX) + 0.05, to: rows ? b.maxY : b.maxX, by: 0.1) {
                let hits = AvatarGeometry.crossings(polys, at: s, rows: rows)
                var w = 0, start: Double?, end: Double?
                for (x, d) in hits {
                    let was = w; w += d
                    if was == 0 && w != 0 && start == nil { start = x }
                    if was != 0 && w == 0 { end = x }
                }
                at.append(s); e.append(low ? start.map { -$0 } ?? .nan : end ?? .nan)
            }
            var k = 0
            while k < e.count {
                if e[k].isNaN { k += 1; continue }
                let a = k
                while k < e.count && !e[k].isNaN { k += 1 }
                let b = k - 1
                var i = a
                while i < b {
                    let d = e[i + 1] - e[i]
                    if abs(d) <= 0.25 { i += 1; continue }
                    var lo = i, hi = i
                    while lo > a && (e[lo] - e[lo - 1]).sign == d.sign && abs(e[lo] - e[lo - 1]) > 0.06 { lo -= 1 }
                    while hi + 1 < b && (e[hi + 2] - e[hi + 1]).sign == d.sign && abs(e[hi + 2] - e[hi + 1]) > 0.06 { hi += 1 }
                    let size = e[hi + 1] - e[lo]
                    if Double(lo - a) * 0.1 >= 1 && Double(b - hi - 1) * 0.1 >= 1 && abs(size) >= 0.3 && abs(size) < 2.5 {
                        result.append(Seam(side: side, at: at[i], size: AvatarPath.rounded(size)))
                    }
                    i = hi + 1
                }
            }
        }
        return result
    }
}
