// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

nonisolated enum AvatarContour {
    static func loops(values: [Double], nx: Int, ny: Int, x0: Double, y0: Double, step: Double) -> [[AvatarPoint]] {
        var points: [Int: AvatarPoint] = [:]
        var links: [Int: [Int]] = [:]
        var keys: [Int] = []
        func point(_ key: Int) {
            if points[key] != nil { return }
            let idx = key >> 1
            let i = idx % nx
            let j = idx / nx
            let a = values[idx]
            let vertical = key & 1 != 0
            let b = values[idx + (vertical ? nx : 1)]
            let t = a / (a - b)
            points[key] = AvatarPoint(x0 + (Double(i) + (vertical ? 0 : t)) * step, y0 + (Double(j) + (vertical ? t : 0)) * step)
        }
        func link(_ p: Int, _ q: Int) {
            point(p)
            point(q)
            if links[p] == nil { keys.append(p) }
            if links[q] == nil { keys.append(q) }
            links[p, default: []].append(q)
            links[q, default: []].append(p)
        }
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let idx = j * nx + i
                let tl = values[idx] >= 0
                let tr = values[idx + 1] >= 0
                let br = values[idx + nx + 1] >= 0
                let bl = values[idx + nx] >= 0
                let code = (tl ? 8 : 0) | (tr ? 4 : 0) | (br ? 2 : 0) | (bl ? 1 : 0)
                if code == 0 || code == 15 { continue }
                let top = 2 * idx
                let bottom = 2 * (idx + nx)
                let left = top + 1
                let right = top + 3
                if code == 10 || code == 5 {
                    let center = (values[idx] + values[idx + 1] + values[idx + nx + 1] + values[idx + nx]) / 4 >= 0
                    if (code == 10) == center {
                        link(top, right)
                        link(bottom, left)
                    } else {
                        link(left, top)
                        link(right, bottom)
                    }
                } else {
                    var crossed: [Int] = []
                    if tl != tr { crossed.append(top) }
                    if tr != br { crossed.append(right) }
                    if br != bl { crossed.append(bottom) }
                    if bl != tl { crossed.append(left) }
                    link(crossed[0], crossed[1])
                }
            }
        }
        var seen = Set<Int>()
        var result: [[AvatarPoint]] = []
        for start in keys where !seen.contains(start) {
            var loop: [AvatarPoint] = []
            var prev = -1
            var cur = start
            while !seen.contains(cur) {
                seen.insert(cur)
                if let p = points[cur] { loop.append(p) }
                guard let next = links[cur]?.first(where: { $0 != prev && !seen.contains($0) }) else { break }
                prev = cur
                cur = next
            }
            if loop.count >= 3 { result.append(loop) }
        }
        return result
    }
    static func simplify(_ loop: [AvatarPoint], tolerance: Double = 0.04) -> [AvatarPoint] {
        guard loop.count > 8 else { return loop }
        var far = 0
        var best = -1.0
        for k in 1..<loop.count {
            let d = hypot(loop[k].x - loop[0].x, loop[k].y - loop[0].y)
            if d > best {
                best = d
                far = k
            }
        }
        var keep = Set([0, far])
        var stack = [(0, far), (far, loop.count)]
        while let (s, e) = stack.popLast() {
            let a = loop[s]
            let b = loop[e % loop.count]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = hypot(dx, dy)
            var idx: Int?
            var maxD = tolerance
            if e > s + 1 {
                for k in (s + 1)..<e {
                    let p = loop[k]
                    let d = len == 0 ? hypot(p.x - a.x, p.y - a.y) : abs(dx * (a.y - p.y) - dy * (a.x - p.x)) / len
                    if d > maxD {
                        maxD = d
                        idx = k
                    }
                }
            }
            if let idx {
                keep.insert(idx)
                stack += [(s, idx), (idx, e)]
            }
        }
        return loop.enumerated().compactMap { keep.contains($0.offset) ? $0.element : nil }
    }
}

/// Preparation-only edge buckets; not retained by the prepared volume.
nonisolated struct AvatarEdgeIndex {
    let ox: Double, oy: Double, span: Int
    var buckets: [Int: [Int]] = [:]
    var edges: [(AvatarPoint, AvatarPoint)] = []
    init(_ polys: [[AvatarPoint]], _ b: AvatarBounds) {
        ox = b.minX - 4
        oy = b.minY - 4
        span = Int(ceil((max(b.width, b.height) + 8) / 3)) + 1
        for poly in polys where !poly.isEmpty {
            var a = poly[poly.count - 1]
            for p in poly {
                let k = edges.count
                edges.append((a, p))
                for y in cy(min(a.y, p.y))...cy(max(a.y, p.y)) {
                    for x in cx(min(a.x, p.x))...cx(max(a.x, p.x)) { buckets[y * span + x, default: []].append(k) }
                }
                a = p
            }
        }
    }
    func cx(_ x: Double) -> Int { max(0, min(span - 1, Int(floor((x - ox) / 3)))) }
    func cy(_ y: Double) -> Int { max(0, min(span - 1, Int(floor((y - oy) / 3)))) }
    func distance(_ p: AvatarPoint) -> Double {
        let bx = cx(p.x)
        let by = cy(p.y)
        var best = Double.infinity
        for r in 0..<span {
            for y in (by - r)...(by + r) where y >= 0 && y < span {
                let edge = y == by - r || y == by + r
                for x in stride(from: bx - r, through: bx + r, by: edge ? 1 : max(1, 2 * r)) where x >= 0 && x < span {
                    if let list = buckets[y * span + x] {
                        for k in list { best = min(best, AvatarGeometry.distance(p, edges[k].0, edges[k].1)) }
                    }
                }
            }
            if best <= Double(r) * 3 { break }
        }
        return best
    }
}

nonisolated struct AvatarGrid {
    let x0: Double, y0: Double, step: Double, nx: Int, ny: Int
    var sd: [Double], h: [Double]
    struct Box {
        var i0: Int
        var i1: Int
        var j0: Int
        var j1: Int
        var top: Double
    }
    init(polys: [[AvatarPoint]], bounds b: AvatarBounds, step: Double, height: (Double, Double, Double) -> Double) {
        self.step = step
        x0 = b.minX - 1
        y0 = b.minY - 1
        nx = Int(ceil((b.width + 2) / step)) + 1
        ny = Int(ceil((b.height + 2) / step)) + 1
        sd = .init(repeating: 0, count: nx * ny)
        h = sd
        let index = AvatarEdgeIndex(polys, b)
        let xs = (0..<nx).map { x0 + Double($0) * step }
        for j in 0..<ny {
            let y = y0 + Double(j) * step
            let inside = AvatarGeometry.row(polys, y, xs)
            for i in 0..<nx {
                let d = index.distance(AvatarPoint(xs[i], y))
                let k = j * nx + i
                sd[k] = inside[i] ? d : -d
                h[k] = inside[i] ? height(xs[i], y, d) : 0
            }
        }
    }
    func levelLoops(_ level: Double, box: Box? = nil) -> [[AvatarPoint]] {
        let i0 = max(0, (box?.i0 ?? 1) - 1)
        let i1 = min(nx - 1, (box?.i1 ?? (nx - 2)) + 1)
        let j0 = max(0, (box?.j0 ?? 1) - 1)
        let j1 = min(ny - 1, (box?.j1 ?? (ny - 2)) + 1)
        let width = i1 - i0 + 1
        let height = j1 - j0 + 1
        var values = [Double](repeating: 0, count: width * height)
        for j in 0..<height {
            for i in 0..<width {
                let k = (j + j0) * nx + i + i0
                var v = min(h[k] - level, 4 * sd[k])
                if let b = box { v = min(v, 4 * step * Double(min(i + i0 - b.i0, b.i1 - i - i0, j + j0 - b.j0, b.j1 - j - j0))) }
                values[j * width + i] = v
            }
        }
        return AvatarContour.loops(
            values: values, nx: width, ny: height, x0: x0 + Double(i0) * step, y0: y0 + Double(j0) * step, step: step
        )
        .map { AvatarContour.simplify($0) }.filter { $0.count >= 3 }
    }
    func thinBoxes() -> [Box] {
        let reach = Int(ceil(5 / step))
        let grow = Int(ceil(2 / step))
        var rows = [Double](repeating: 0, count: nx * ny)
        var widest = rows
        for j in 0..<ny {
            for i in 0..<nx {
                for k in max(0, i - reach)...min(nx - 1, i + reach) { rows[j * nx + i] = max(rows[j * nx + i], sd[j * nx + k]) }
            }
        }
        for i in 0..<nx {
            for j in 0..<ny {
                for k in max(0, j - reach)...min(ny - 1, j + reach) { widest[j * nx + i] = max(widest[j * nx + i], rows[k * nx + i]) }
            }
        }
        var seen = [Bool](repeating: false, count: nx * ny)
        var boxes: [Box] = []
        for start in 0..<(nx * ny) where !seen[start] && sd[start] > 0 && widest[start] < 4 {
            var b = Box(i0: nx, i1: -1, j0: ny, j1: -1, top: 0)
            var stack = [start]
            var cells = 0
            seen[start] = true
            while let k = stack.popLast() {
                let i = k % nx
                let j = k / nx
                cells += 1
                b.top = max(b.top, h[k])
                b.i0 = min(b.i0, i)
                b.i1 = max(b.i1, i)
                b.j0 = min(b.j0, j)
                b.j1 = max(b.j1, j)
                for n in [i > 0 ? k - 1 : -1, i < nx - 1 ? k + 1 : -1, j > 0 ? k - nx : -1, j < ny - 1 ? k + nx : -1] {
                    if n >= 0 && !seen[n] && sd[n] > 0 && widest[n] < 4 {
                        seen[n] = true
                        stack.append(n)
                    }
                }
            }
            if Double(cells) * step * step < 2 { continue }
            b.i0 = max(0, b.i0 - grow)
            b.i1 = min(nx - 1, b.i1 + grow)
            b.j0 = max(0, b.j0 - grow)
            b.j1 = min(ny - 1, b.j1 + grow)
            boxes.append(b)
        }
        for a in boxes.indices {
            if a >= boxes.count { break }
            var b = a + 1
            while b < boxes.count {
                let p = boxes[a]
                let q = boxes[b]
                if p.i0 > q.i1 || q.i0 > p.i1 || p.j0 > q.j1 || q.j0 > p.j1 {
                    b += 1
                    continue
                }
                boxes[a] = Box(i0: min(p.i0, q.i0), i1: max(p.i1, q.i1), j0: min(p.j0, q.j0), j1: max(p.j1, q.j1), top: max(p.top, q.top))
                boxes.remove(at: b)
                b = a + 1
            }
        }
        return boxes
    }
    func columnLoops(_ c0: Int, _ c1: Int, edgeHeight: (Double, Double) -> Double) -> [[AvatarPoint]] {
        var ds = [Double](repeating: -.infinity, count: ny)
        var hs = [Double](repeating: 0, count: ny)
        for j in 0..<ny {
            for c in c0...c1 {
                let k = j * nx + c
                ds[j] = max(ds[j], sd[k])
                if sd[k] > 0 { hs[j] = max(hs[j], h[k]) }
            }
        }
        func yAt(_ j: Int) -> Double { y0 + Double(j) * step }
        func edge(_ i: Int, _ o: Int) -> Double { yAt(i) + (yAt(o) - yAt(i)) * ds[i] / (ds[i] - ds[o]) }
        func rim(_ y: Double, _ j: Int) -> Double { min(hs[j], (c0...c1).map { edgeHeight(x0 + Double($0) * step, y) }.max() ?? 0) }
        var j = 0
        var loops: [[AvatarPoint]] = []
        while j < ny {
            if ds[j] <= 0 {
                j += 1
                continue
            }
            let j0 = j
            while j < ny && ds[j] > 0 { j += 1 }
            let j1 = j - 1
            let top = j0 > 0 ? edge(j0, j0 - 1) : yAt(j0)
            let bottom = j1 < ny - 1 ? edge(j1, j1 + 1) : yAt(j1)
            var right = [AvatarPoint(j0 > 0 ? rim(top, j0) : hs[j0], top)]
            for k in j0...j1 { right.append(AvatarPoint(hs[k], yAt(k))) }
            right.append(AvatarPoint(j1 < ny - 1 ? rim(bottom, j1) : hs[j1], bottom))
            if (right.map(\.x).max() ?? 0) < 0.05 { continue }
            loops.append(AvatarContour.simplify(right + right.reversed().map { AvatarPoint(-$0.x, $0.y) }))
        }
        return loops
    }
}
