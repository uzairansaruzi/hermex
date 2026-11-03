import Foundation
import SwiftUI

/// An avatar the host's model drew from a description: one path, its eyes and a short name,
/// stored inline under a Hermex-owned key in `ui_meta["hermes-bots"]`, the way `expression` is.
/// Desktop and older Hermex builds ignore the key and keep drawing the stored `shape`.
struct BotGeneratedAvatar: Equatable, Sendable {
    static let lookKey = "hermexAvatar"

    var name: String
    var path: String
    var eyes: BotAvatarEyes

    init(name: String, path: String, eyes: BotAvatarEyes) {
        self.name = name; self.path = path; self.eyes = eyes
    }

    /// Reads a stored value, or a model's answer before `validate` checks it. Unknown fields are ignored.
    init?(json: BotJSON) {
        let eyes = json["eyes"]
        guard let path = json["path"].text, let x = eyes["x"].number, let y = eyes["y"].number,
              let spacing = eyes["spacing"].number, let scale = eyes["scale"].number else { return nil }
        self.init(name: json["name"].text ?? "", path: path, eyes: BotAvatarEyes(x: x, y: y, spacing: spacing, scale: scale))
    }

    var json: BotJSON {
        .object([
            "name": .string(name), "path": .string(path),
            "eyes": .object(["x": .number(eyes.x), "y": .number(eyes.y), "spacing": .number(eyes.spacing), "scale": .number(eyes.scale)])
        ])
    }

    /// Reads a model's answer, which may be wrapped in prose or a code fence. Returns the avatar,
    /// or the problems in words a repair prompt can act on.
    static func read(answer: String) -> Result<BotGeneratedAvatar, BotAvatarGeneration.Failure> {
        guard let open = answer.firstIndex(of: "{"), let close = answer.lastIndex(of: "}"), open < close,
              let json = try? JSONDecoder().decode(BotJSON.self, from: Data(answer[open...close].utf8)),
              let avatar = BotGeneratedAvatar(json: json) else {
            return .failure(.unreadable(["the answer is not the requested JSON object"]))
        }
        let problems = avatar.problems
        return problems.isEmpty ? .success(avatar.trimmedName) : .failure(.unreadable(problems))
    }

    private var trimmedName: BotGeneratedAvatar {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return copy
    }

    /// Whether the eye numbers are sane. A damaged or newer stored value that fails this draws
    /// the bot's shape instead, and a save still writes the value back unchanged.
    var hasDrawableEyes: Bool {
        (0.6...1.8).contains(eyes.scale) && eyes.spacing >= 7 * eyes.scale && eyes.spacing <= 40
            && (0...100).contains(eyes.x) && (0...100).contains(eyes.y)
    }

    /// What stops this avatar drawing properly. The path must parse and fill most of the box's
    /// safe area, and both neutral eyes must sit fully on the body.
    var problems: [String] {
        guard let body = BotAvatarPathData.path(path) else {
            return ["path must use only absolute M, L, Q, C and Z commands, at most \(BotAvatarPathData.maxSegments) segments"]
        }
        var found: [String] = []
        let box = body.boundingRect
        if box.minX < 6 || box.minY < 6 || box.maxX > 94 || box.maxY > 94 { found.append("path must stay between 8 and 92") }
        if max(box.width, box.height) < 40 || min(box.width, box.height) < 14 { found.append("body must be at least 40 units long and 14 wide") }
        guard hasDrawableEyes else {
            return found + ["eyes.scale must be 0.6 to 1.8, and eyes.spacing at least 7 x scale and at most 40"]
        }
        let halfWidth = 2 * eyes.scale, halfHeight = 5.5 * eyes.scale
        let onBody = [-1.0, 1.0].allSatisfy { side in
            let center = CGPoint(x: eyes.x + side * eyes.spacing / 2, y: eyes.y)
            return [center, CGPoint(x: center.x - halfWidth, y: center.y), CGPoint(x: center.x + halfWidth, y: center.y),
                    CGPoint(x: center.x, y: center.y - halfHeight), CGPoint(x: center.x, y: center.y + halfHeight)]
                .allSatisfy { body.contains($0) }
        }
        if !onBody { found.append("both eyes must sit fully on solid fill, not in a hole or past the edge") }
        return found
    }
}

/// Stored avatar paths, parsed once. The grammar is deliberately small: absolute M, L, Q, C and Z,
/// which every ready-made path uses and the design prompt asks the model for.
enum BotAvatarPathData {
    static let maxCharacters = 6000
    static let maxSegments = 400

    private final class Parsed { let path: Path?; init(_ path: Path?) { self.path = path } }
    private nonisolated(unsafe) static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 64
        return cache
    }()

    /// The path for `data`, or nil when it breaks the grammar. Safe from any thread.
    static func path(_ data: String) -> Path? {
        let key = data as NSString
        if let hit = cache.object(forKey: key) { return hit.path }
        let parsed = parse(data)
        cache.setObject(Parsed(parsed), forKey: key)
        return parsed
    }

    private static func parse(_ data: String) -> Path? {
        guard data.utf8.count <= maxCharacters else { return nil }
        var tokens: [Substring] = []
        var start: String.Index?
        var index = data.startIndex
        while index < data.endIndex {
            let character = data[index]
            let isCommand = "MLQCZ".contains(character)
            let startsNumber = character == "-" && start != nil && data[data.index(before: index)] != "e"
            if character == " " || character == "," || character == "\n" || character == "\t" || isCommand || startsNumber {
                if let begun = start { tokens.append(data[begun..<index]); start = nil }
                if isCommand { tokens.append(data[index...index]) }
                if startsNumber { start = index }
            } else if start == nil {
                start = index
            }
            index = data.index(after: index)
        }
        if let begun = start { tokens.append(data[begun...]) }

        var path = Path()
        var segments = 0
        var position = 0
        var open = false
        func point() -> CGPoint? {
            guard position + 1 < tokens.count, let x = Double(tokens[position]), let y = Double(tokens[position + 1]),
                  x.isFinite, y.isFinite else { return nil }
            position += 2
            return CGPoint(x: x, y: y)
        }
        while position < tokens.count {
            let command = tokens[position]
            position += 1
            segments += 1
            guard segments <= maxSegments else { return nil }
            switch command {
            case "M":
                guard let to = point() else { return nil }
                path.move(to: to); open = true
            case "L":
                guard open, let to = point() else { return nil }
                path.addLine(to: to)
            case "Q":
                guard open, let control = point(), let to = point() else { return nil }
                path.addQuadCurve(to: to, control: control)
            case "C":
                guard open, let first = point(), let second = point(), let to = point() else { return nil }
                path.addCurve(to: to, control1: first, control2: second)
            case "Z":
                guard open else { return nil }
                path.closeSubpath(); open = false
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }
}
