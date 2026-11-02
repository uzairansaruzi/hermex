import Foundation

/// A drawn avatar as it is stored: inline in the bot's `ui_meta["hermes-bots"]` under one
/// Hermex-owned key, the way `expression` is, so it travels with the bot and survives a Desktop
/// save. Desktop and older Hermex builds ignore the key and keep drawing the stored `shape`.
nonisolated struct BotDrawnAvatar: Hashable, Sendable {
    static let lookKey = "hermexAvatar"
    static let depthRange = 0...14
    /// Where a ready-made avatar starts; a classic shape starts flat.
    static let naturalDepth = 6

    var definition: BotAvatarDefinition
    /// Whole steps only, which also keeps the render cache small.
    var depth: Int
    /// A `#rrggbb` color, or nil for eyes that contrast with the body on their own.
    var eyeColor: String?

    init(definition: BotAvatarDefinition, depth: Int, eyeColor: String? = nil) {
        self.definition = definition
        self.depth = min(max(depth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        self.eyeColor = eyeColor
    }

    /// Reads a stored value without validating it, so a view body can afford it. The render
    /// store validates off the main thread, and a bad value falls back to the classic face.
    init?(json: BotJSON) {
        let eyes = json["definition"]["eyes"]
        guard let id = json["definition"]["id"].text, let name = json["definition"]["name"].text,
              let path = json["definition"]["body"]["path"].text,
              let x = eyes["x"].number, let y = eyes["y"].number,
              let spacing = eyes["spacing"].number, let scale = eyes["scale"].number else { return nil }
        self.init(definition: BotAvatarDefinition(version: json["definition"]["version"].integer ?? 1, id: id, name: name,
                                                  body: .init(path: path),
                                                  eyes: .init(x: x, y: y, spacing: spacing, scale: scale)),
                  depth: json["depth"].integer ?? 0, eyeColor: json["eyeColor"].text)
    }

    var json: BotJSON {
        var fields: [String: BotJSON] = [
            "definition": .object([
                "version": .number(Double(definition.version)), "id": .string(definition.id), "name": .string(definition.name),
                "body": .object(["path": .string(definition.body.path)]),
                "eyes": .object(["x": .number(definition.eyes.x), "y": .number(definition.eyes.y),
                                 "spacing": .number(definition.eyes.spacing), "scale": .number(definition.eyes.scale)])
            ]),
            "depth": .number(Double(depth))
        ]
        if let eyeColor { fields["eyeColor"] = .string(eyeColor) }
        return .object(fields)
    }

    var lean: Double { BotAvatarClassic.isClassic(definition) ? BotAvatarClassic.lean : 0 }
}
