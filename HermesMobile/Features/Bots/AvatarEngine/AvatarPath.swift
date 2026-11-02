import CoreGraphics
// Open Bot Avatar, Copyright (c) Dominik Scholz, MIT license.
// Native port of packages/core at 3a5119877844165eebafe57d3100da475f67d0a8.
import Foundation

nonisolated struct AvatarPoint: Sendable, Equatable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}
nonisolated struct AvatarBounds: Sendable {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: AvatarPoint { AvatarPoint((minX + maxX) / 2, (minY + maxY) / 2) }
    init(_ polys: [[AvatarPoint]]) {
        for p in polys.joined() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
    }
}
nonisolated struct AvatarEngineError: Error { let errors: [String] }
nonisolated struct AvatarSegment: Sendable {
    let command: Character
    let values: [Double]
}
nonisolated enum AvatarPath {
    static func fail(_ text: String) -> AvatarEngineError { AvatarEngineError(errors: [text]) }
    static func rounded(_ n: Double, places: Double = 100) -> Double { floor(n * places + 0.5) / places }
    static func number(_ n: Double) -> String {
        let r = rounded(n)
        return r == 0 ? "0" : r == r.rounded() && abs(r) < 1e15 ? String(Int64(r)) : String(r)
    }
    static func serialize(_ segments: [AvatarSegment]) -> String {
        segments.map { String($0.command) + $0.values.map(number).joined(separator: " ") }.joined()
    }
    /// Bounded tokenizer and absolute normalizer. Never accepts model text as drawing commands directly.
    static func parse(_ text: String) throws -> [AvatarSegment] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("path is empty") }
        guard text.utf16.count <= 6000 else { throw fail("path longer than 6000 characters") }
        let pattern = "[MmLlHhVvCcSsQqTtAaZz]|[+-]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[\\s,]+"
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var tokens: [String] = []
        var offset = 0
        while offset < ns.length {
            guard let m = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: offset, length: ns.length - offset))
            else { throw fail("cannot parse path") }
            let token = ns.substring(with: m.range)
            if token.first != ",", token.trimmingCharacters(in: .whitespacesAndNewlines).first != nil,
                token.rangeOfCharacter(from: CharacterSet(charactersIn: " ,\t\n\r")) == nil
            {
                tokens.append(token)
            }
            offset = NSMaxRange(m.range)
        }
        let counts: [Character: Int] = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0]
        var out: [AvatarSegment] = []
        var i = 0
        var cmd: Character = " "
        var cx = 0.0
        var cy = 0.0
        var sx = 0.0
        var sy = 0.0
        var prevC: AvatarPoint?
        var prevQ: AvatarPoint?
        var open = false
        var subpaths = 0
        while i < tokens.count {
            if tokens[i].count == 1, let c = tokens[i].first, counts[Character(c.uppercased())] != nil {
                cmd = c
                i += 1
                if cmd == "Z" || cmd == "z" {
                    guard open else { throw fail("Z without an open subpath") }
                    out.append(.init(command: "Z", values: []))
                    cx = sx
                    cy = sy
                    prevC = nil
                    prevQ = nil
                    open = false
                    continue
                }
            }
            let up = Character(cmd.uppercased())
            let relative = cmd != up
            guard let count = counts[up], count > 0, !out.isEmpty || up == "M" else {
                throw fail("path must start with M; no numbers after Z")
            }
            guard i + count <= tokens.count else { throw fail("command \(cmd) expects \(count) numbers") }
            let a = try tokens[i..<(i + count)].map { token -> Double in
                guard let n = Double(token), n.isFinite else { throw fail("command \(cmd) expects finite numbers") }
                return n
            }
            i += count
            let ox = relative ? cx : 0
            let oy = relative ? cy : 0
            var nc: AvatarPoint?
            var nq: AvatarPoint?
            var values: [Double] = []
            var kind = up
            switch up {
            case "M":
                if open { out.append(.init(command: "Z", values: [])) }
                cx = a[0] + ox
                cy = a[1] + oy
                sx = cx
                sy = cy
                values = [cx, cy]
                subpaths += 1
                open = true
                cmd = relative ? "l" : "L"
            case "L":
                cx = a[0] + ox
                cy = a[1] + oy
                values = [cx, cy]
            case "H":
                cx = a[0] + ox
                values = [cx, cy]
                kind = "L"
            case "V":
                cy = a[0] + oy
                values = [cx, cy]
                kind = "L"
            case "C":
                values = [a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy, a[4] + ox, a[5] + oy]
                nc = AvatarPoint(values[2], values[3])
                cx = values[4]
                cy = values[5]
            case "S":
                values = [prevC.map { 2 * cx - $0.x } ?? cx, prevC.map { 2 * cy - $0.y } ?? cy, a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy]
                kind = "C"
                nc = AvatarPoint(values[2], values[3])
                cx = values[4]
                cy = values[5]
            case "Q":
                values = [a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy]
                nq = AvatarPoint(values[0], values[1])
                cx = values[2]
                cy = values[3]
            case "T":
                values = [prevQ.map { 2 * cx - $0.x } ?? cx, prevQ.map { 2 * cy - $0.y } ?? cy, a[0] + ox, a[1] + oy]
                kind = "Q"
                nq = AvatarPoint(values[0], values[1])
                cx = values[2]
                cy = values[3]
            case "A":
                guard a[0] >= 0, a[1] >= 0 else { throw fail("arc radii must be non-negative") }
                guard [0.0, 1].contains(a[3]), [0.0, 1].contains(a[4]) else { throw fail("arc flags must be 0 or 1") }
                cx = a[5] + ox
                cy = a[6] + oy
                values = Array(a.prefix(5)) + [cx, cy]
            default: throw fail("unsupported command")
            }
            for (k, v) in values.enumerated() {
                if kind == "A" && (2...4).contains(k) { continue }
                guard v.isFinite, v >= -20, v <= 120 else { throw fail("coordinate far outside the 0..100 viewBox") }
            }
            out.append(.init(command: kind, values: values))
            prevC = nc
            prevQ = nq
            guard out.count <= 400, subpaths <= 16 else { throw fail("more than 400 segments or 16 subpaths") }
        }
        if open { out.append(.init(command: "Z", values: [])) }
        return out
    }

    static func arc(_ p: AvatarPoint, _ a: [Double]) -> [AvatarPoint] {
        var rx = a[0]
        var ry = a[1]
        let x = a[5]
        let y = a[6]
        if rx == 0 || ry == 0 || (p.x == x && p.y == y) { return [AvatarPoint(x, y)] }
        // Reducing rotation first prevents overflow from an otherwise valid finite angle.
        let phi = a[2].truncatingRemainder(dividingBy: 360) * .pi / 180
        let co = cos(phi)
        let si = sin(phi)
        let dx = (p.x - x) / 2
        let dy = (p.y - y) / 2
        let xp = co * dx + si * dy
        let yp = -si * dx + co * dy
        let lambda = pow(xp / rx, 2) + pow(yp / ry, 2)
        guard lambda.isFinite else { return [AvatarPoint(x, y)] }
        if lambda > 1 {
            let k = sqrt(lambda)
            rx *= k
            ry *= k
        }
        let num = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
        let den = rx * rx * yp * yp + ry * ry * xp * xp
        var coef = sqrt(max(0, num / den))
        if a[3] == a[4] { coef = -coef }
        let cxp = coef * rx * yp / ry
        let cyp = -coef * ry * xp / rx
        let cx = co * cxp - si * cyp + (p.x + x) / 2
        let cy = si * cxp + co * cyp + (p.y + y) / 2
        let ux = (xp - cxp) / rx
        let uy = (yp - cyp) / ry
        let vx = (-xp - cxp) / rx
        let vy = (-yp - cyp) / ry
        let t1 = atan2(uy, ux)
        var dt = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if a[4] == 0 && dt > 0 { dt -= 2 * .pi }
        if a[4] == 1 && dt < 0 { dt += 2 * .pi }
        guard dt.isFinite else { return [AvatarPoint(x, y)] }
        let steps = max(4, Int(ceil(abs(dt) / (.pi / 2) * 6)))
        return (1...steps).map { k in
            let t = t1 + dt * Double(k) / Double(steps)
            let ex = rx * cos(t)
            let ey = ry * sin(t)
            return AvatarPoint(co * ex - si * ey + cx, si * ex + co * ey + cy)
        }
    }

    /// SVG endpoint arc converted to a native transformed ellipse; sampling is only for analysis.
    static func addArc(_ path: CGMutablePath, from p: AvatarPoint, values a: [Double]) {
        var rx = a[0]
        var ry = a[1]
        let x = a[5]
        let y = a[6]
        if rx == 0 || ry == 0 || (p.x == x && p.y == y) {
            path.addLine(to: CGPoint(x: x, y: y))
            return
        }
        let phi = a[2].truncatingRemainder(dividingBy: 360) * .pi / 180
        let co = cos(phi)
        let si = sin(phi)
        let dx = (p.x - x) / 2
        let dy = (p.y - y) / 2
        let xp = co * dx + si * dy
        let yp = -si * dx + co * dy
        let lambda = pow(xp / rx, 2) + pow(yp / ry, 2)
        guard lambda.isFinite else {
            path.addLine(to: CGPoint(x: x, y: y))
            return
        }
        if lambda > 1 {
            let k = sqrt(lambda)
            rx *= k
            ry *= k
        }
        let numerator = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
        let denominator = rx * rx * yp * yp + ry * ry * xp * xp
        var coef = sqrt(max(0, numerator / denominator))
        if a[3] == a[4] { coef = -coef }
        let cxp = coef * rx * yp / ry
        let cyp = -coef * ry * xp / rx
        let cx = co * cxp - si * cyp + (p.x + x) / 2
        let cy = si * cxp + co * cyp + (p.y + y) / 2
        let ux = (xp - cxp) / rx
        let uy = (yp - cyp) / ry
        let vx = (-xp - cxp) / rx
        let vy = (-yp - cyp) / ry
        let start = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if a[4] == 0 && delta > 0 { delta -= 2 * .pi }
        if a[4] == 1 && delta < 0 { delta += 2 * .pi }
        guard delta.isFinite else {
            path.addLine(to: CGPoint(x: x, y: y))
            return
        }
        let transform = CGAffineTransform(a: rx * co, b: rx * si, c: -ry * si, d: ry * co, tx: cx, ty: cy)
        path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: start + delta, clockwise: delta < 0, transform: transform)
    }

    static func flatten(_ segments: [AvatarSegment]) -> [[AvatarPoint]] {
        var polys: [[AvatarPoint]] = []
        var cur: [AvatarPoint] = []
        var p = AvatarPoint(0, 0)
        for s in segments {
            let a = s.values
            switch s.command {
            case "M":
                if !cur.isEmpty { polys.append(cur) }
                cur = [AvatarPoint(a[0], a[1])]
                p = cur[0]
            case "L":
                p = AvatarPoint(a[0], a[1])
                cur.append(p)
            case "C", "Q":
                let cubic = s.command == "C"
                let n = cubic ? 12 : 8
                for k in 1...n {
                    let t = Double(k) / Double(n)
                    let u = 1 - t
                    if cubic {
                        let x = u * u * u * p.x + 3 * u * u * t * a[0] + 3 * u * t * t * a[2] + t * t * t * a[4]
                        let y = u * u * u * p.y + 3 * u * u * t * a[1] + 3 * u * t * t * a[3] + t * t * t * a[5]
                        cur.append(AvatarPoint(x, y))
                    } else {
                        cur.append(
                            AvatarPoint(u * u * p.x + 2 * u * t * a[0] + t * t * a[2], u * u * p.y + 2 * u * t * a[1] + t * t * a[3]))
                    }
                }
                p = AvatarPoint(a[a.count - 2], a[a.count - 1])
            case "A":
                cur += arc(p, a)
                p = AvatarPoint(a[5], a[6])
            case "Z":
                if let first = cur.first {
                    polys.append(cur)
                    p = first
                }
                cur = []
            default: break
            }
        }
        if !cur.isEmpty { polys.append(cur) }
        return polys.filter { $0.count >= 3 }
    }

    static func cgPath(_ segments: [AvatarSegment]) -> CGPath {
        let path = CGMutablePath()
        var p = AvatarPoint(0, 0)
        for s in segments {
            let a = s.values
            switch s.command {
            case "M":
                p = AvatarPoint(a[0], a[1])
                path.move(to: p.cg)
            case "L":
                p = AvatarPoint(a[0], a[1])
                path.addLine(to: p.cg)
            case "C":
                p = AvatarPoint(a[4], a[5])
                path.addCurve(to: p.cg, control1: CGPoint(x: a[0], y: a[1]), control2: CGPoint(x: a[2], y: a[3]))
            case "Q":
                p = AvatarPoint(a[2], a[3])
                path.addQuadCurve(to: p.cg, control: CGPoint(x: a[0], y: a[1]))
            case "A":
                addArc(path, from: p, values: a)
                p = AvatarPoint(a[5], a[6])
            case "Z":
                path.closeSubpath()
                p = AvatarPoint(path.currentPoint.x, path.currentPoint.y)
            default: break
            }
        }
        return path.copy()!
    }
    static func polygonPath(_ polys: [[AvatarPoint]]) -> CGPath {
        let path = CGMutablePath()
        for poly in polys where !poly.isEmpty {
            path.move(to: CGPoint(x: rounded(poly[0].x, places: 10), y: rounded(poly[0].y, places: 10)))
            for p in poly.dropFirst() { path.addLine(to: CGPoint(x: rounded(p.x, places: 10), y: rounded(p.y, places: 10))) }
            path.closeSubpath()
        }
        return path.copy()!
    }
}
