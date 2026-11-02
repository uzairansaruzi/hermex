// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation
import CoreFoundation

nonisolated struct BotAvatarDefinition: Codable, Hashable, Sendable {
    struct Body: Codable, Hashable, Sendable { var path: String }
    struct Eyes: Codable, Hashable, Sendable {
        var x: Double; var y: Double; var spacing: Double; var scale: Double
        var centers: [AvatarPoint] { [AvatarPoint(x - spacing / 2, y), AvatarPoint(x + spacing / 2, y)] }
    }
    var version: Int
    var id: String
    var name: String
    var body: Body
    var eyes: Eyes
}

nonisolated enum BotAvatarValidator {
    enum Validation: Sendable {
        case valid(BotAvatarDefinition)
        case invalid([String])
        func get() throws -> BotAvatarDefinition {
            switch self { case .valid(let d): return d; case .invalid(let errors): throw AvatarEngineError(errors: errors) }
        }
    }
    /// Import gate, including unknown keys. Codable alone is for already trusted storage.
    static func validate(json: Data) -> Validation {
        guard json.count <= 32_768 else { return .invalid(["definition exceeds 32768 bytes"]) }
        guard let input = try? JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed),
              let obj = input as? [String: Any] else { return .invalid(["definition must be a JSON object"]) }
        var errors: [String] = []
        func unknown(_ obj: [String: Any], _ keys: Set<String>, _ prefix: String = "") {
            for key in obj.keys.sorted() where !keys.contains(key) { errors.append("unknown field \(prefix)\(key)") }
        }
        func num(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        unknown(obj, ["version", "id", "name", "body", "eyes"])
        if num(obj["version"]) != 1 { errors.append("version must be 1") }
        let id = obj["id"] as? String ?? "", name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.range(of: "^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$", options: .regularExpression) == nil { errors.append("id must be a lowercase slug of 1-40 chars") }
        if name.isEmpty || name.utf16.count > 40 || name.unicodeScalars.contains(where: { $0.value < 32 || $0 == "<" || $0 == ">" }) { errors.append("name must be 1-40 printable characters without < or >") }
        var path = ""
        if let body = obj["body"] as? [String: Any] {
            unknown(body, ["path"], "body.")
            if let p = body["path"] as? String { path = p } else { errors.append("body.path must be a string") }
        } else { errors.append("body must be an object") }
        var eyes: BotAvatarDefinition.Eyes?
        if let e = obj["eyes"] as? [String: Any] {
            unknown(e, ["x", "y", "spacing", "scale"], "eyes.")
            if let x = num(e["x"]), let y = num(e["y"]), let spacing = num(e["spacing"]), let scale = num(e["scale"]) {
                eyes = .init(x: x, y: y, spacing: spacing, scale: scale)
                if scale < 0.6 || scale > 1.8 { errors.append("eyes.scale out of range 0.6..1.8") }
                if spacing < 7 * scale || spacing > 40 { errors.append("eyes.spacing out of range for scale") }
            } else { errors.append("eyes must contain finite numbers") }
        } else { errors.append("eyes must be an object") }
        var normalized = ""
        do {
            normalized = AvatarPath.serialize(try AvatarPath.parse(path))
            let body = try AvatarBodyAnalysis(normalized), b = body.bounds
            if b.minX < 6 || b.minY < 6 || b.maxX > 94 || b.maxY > 94 { errors.append("body.path leaves the safe area; keep geometry within 8..92") }
            if max(b.width, b.height) < 40 || min(b.width, b.height) < 14 { errors.append("body is too small; use at least 40 units on the long side and 14 on the short side") }
            if body.area < 600 { errors.append("body fill area is too thin to carry eyes; must be at least 600 units²") }
            if let eyes, !AvatarEyeFit.fits(body.polys, eyes, margin: 1.2, happy: false) { errors.append("eyes must sit inside the body with 1.2 units margin; move eyes toward the widest solid area, reduce spacing or scale") }
        } catch let e as AvatarEngineError { errors += e.errors.map { "body.path: " + $0 } }
        catch { errors.append("body.path is invalid") }
        guard errors.isEmpty, let eyes else { return .invalid(errors) }
        return .valid(.init(version: 1, id: id, name: name, body: .init(path: normalized), eyes: eyes))
    }
    static func validate(_ definition: BotAvatarDefinition) -> Validation {
        guard let data = try? JSONEncoder().encode(definition) else { return .invalid(["definition contains non-finite numbers"]) }
        return validate(json: data)
    }
}

nonisolated enum AvatarEyeFit {
    static func outline(_ cx: Double, _ cy: Double, _ scale: Double, _ margin: Double, happy: Bool) -> [AvatarPoint] {
        let hw = 2 * scale + margin, hh = 5.5 * scale + margin, straight = hh - hw
        var pts: [AvatarPoint] = []
        for k in 0..<16 {
            let a = Double(k) / 16 * .pi * 2, s = sin(a)
            pts.append(AvatarPoint(cx + cos(a) * hw, cy + s * hw + (s == 0 ? 0 : s > 0 ? 1 : -1) * max(0, straight)))
        }
        for f in [-0.5, 0, 0.5] { pts += [AvatarPoint(cx - hw, cy + f * straight), AvatarPoint(cx + hw, cy + f * straight)] }
        pts.append(AvatarPoint(cx, cy))
        if happy {
            let w = 4 * scale, h = 11 * scale, r = 0.3 * w + margin
            for i in 0...8 {
                let t = Double(i) / 8, m = 1 - t
                let x = m*m*(cx - 0.72*w) + 2*m*t*cx + t*t*(cx + 0.72*w)
                let y = (m*m + t*t)*(cy + 0.1*h) + 2*m*t*(cy - 0.42*h)
                for k in 0..<8 { let a = Double(k) / 8 * .pi * 2; pts.append(AvatarPoint(x + cos(a)*r, y + sin(a)*r)) }
            }
        }
        return pts
    }
    static func fits(_ polys: [[AvatarPoint]], _ eyes: BotAvatarDefinition.Eyes, dx: Double = 0, dy: Double = 0, margin: Double, happy: Bool = true) -> Bool {
        eyes.centers.allSatisfy { c in outline(c.x + dx, c.y + dy, eyes.scale, margin, happy: happy).allSatisfy { AvatarGeometry.inside(polys, $0.x, $0.y) } }
    }
    static func boost(_ body: AvatarBodyAnalysis, _ eyes: BotAvatarDefinition.Eyes) -> Double {
        for k in [1.45, 1.38, 1.3, 1.22, 1.15, 1.08] {
            var e = eyes; e.scale *= k
            if fits(body.polys, e, margin: 3) { return e.scale }
        }
        return eyes.scale
    }
    static func range(_ body: AvatarBodyAnalysis, _ eyes: BotAvatarDefinition.Eyes) -> [Double] {
        [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)].map { x, y in
            [1.0, 0.8, 0.6, 0.4, 0.2].first { fits(body.polys, eyes, dx: x * $0 * 1.5 * eyes.scale, dy: y * $0 * 1.1 * eyes.scale, margin: 1.5) } ?? 0
        }
    }
}
