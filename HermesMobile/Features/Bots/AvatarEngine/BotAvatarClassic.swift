import SwiftUI

/// Hermex's eight classic shapes as path data, generated from their original geometry so a
/// bot with no drawn avatar keeps its exact look. The flat path draws those bots with no
/// engine work. `definition` is the same body for the engine, used once a user gives a
/// classic shape depth or a custom eye setting. Blob's overshoots the engine's body box, so
/// its engine form is scaled in about the center.
nonisolated enum BotAvatarClassic {
    /// Classic eyes keep their lean; ready-made and imported avatars stand upright.
    static let lean = -18.0
    private static let idPrefix = "classic-"

    static func isClassic(_ definition: BotAvatarDefinition) -> Bool { definition.id.hasPrefix(idPrefix) }

    /// The shape a classic definition came from.
    static func shape(of definition: BotAvatarDefinition) -> BotAvatarShape? {
        guard isClassic(definition) else { return nil }
        return BotAvatarShape(rawValue: String(definition.id.dropFirst(idPrefix.count)))
    }

    static func definition(_ shape: BotAvatarShape) -> BotAvatarDefinition {
        let wide = shape != .triangle
        return BotAvatarDefinition(version: 1, id: idPrefix + shape.rawValue, name: shape.rawValue.capitalized,
                                   body: .init(path: engineData(shape)),
                                   eyes: .init(x: 50, y: 46, spacing: wide ? 24 : 21, scale: wide ? 1.6 : 1.4))
    }

    /// The flat body in a 100 by 100 box, parsed once.
    static func flatPath(_ shape: BotAvatarShape) -> Path { flatPaths[shape] ?? Path() }

    private static let flatPaths: [BotAvatarShape: Path] = Dictionary(uniqueKeysWithValues: BotAvatarShape.allCases.map { shape in
        (shape, (try? AvatarPath.parse(flatData(shape))).map { Path(AvatarPath.cgPath($0)) } ?? Path())
    })

    private static func engineData(_ shape: BotAvatarShape) -> String {
        shape == .blob ? "M25.4 22.94C41.8 9 72.96 10.64 79.52 25.4C91 41.8 91 68.04 72.96 79.52C54.1 91 25.4 91 18.84 72.96C9 58.2 9 33.6 25.4 22.94Z" : flatData(shape)
    }

    private static func flatData(_ shape: BotAvatarShape) -> String {
        switch shape {
        case .circle: return "M92 50C92 73.2 73.2 92 50 92C26.8 92 8 73.2 8 50C8 26.8 26.8 8 50 8C73.2 8 92 26.8 92 50Z"
        case .blob: return "M20 17C40 0 78 2 86 20C100 40 100 72 78 86C55 100 20 100 12 78C0 60 0 30 20 17Z"
        case .squircle: return "M92 50L92 50C92 61.72 92 67.76 89.9 74.32C87.27 81.56 81.56 87.27 74.32 89.9C67.76 92 61.72 92 50 92L50 92C38.28 92 32.24 92 25.68 89.9C18.44 87.27 12.73 81.56 10.1 74.32C8 67.76 8 61.72 8 50L8 50C8 38.28 8 32.24 10.1 25.68C12.73 18.44 18.44 12.73 25.68 10.1C32.24 8 38.28 8 50 8L50 8C61.72 8 67.76 8 74.32 10.1C81.56 12.73 87.27 18.44 89.9 25.68C92 32.24 92 38.28 92 50Z"
        case .pill: return "M92 50L92 50C92 51.08 92 54.86 89.98 59.95C87.44 66.93 81.93 72.44 74.95 74.98C68.55 77 62.61 77 50.73 77L49.27 77C37.39 77 31.45 77 25.05 74.98C18.07 72.44 12.56 66.93 10.02 59.95C8 54.86 8 51.08 8 50L8 50C8 48.92 8 45.14 10.02 40.05C12.56 33.07 18.07 27.56 25.05 25.02C31.45 23 37.39 23 49.27 23L50.73 23C62.61 23 68.55 23 74.95 25.02C81.93 27.56 87.44 33.07 89.98 40.05C92 45.14 92 48.92 92 50Z"
        case .triangle: return "M50 8L92 92L8 92Z"
        case .hexagon: return "M50 8L92 30L92 70L50 92L8 70L8 30Z"
        case .cloud: return "M56 62C56 75.25 45.25 86 32 86C18.75 86 8 75.25 8 62C8 48.75 18.75 38 32 38C45.25 38 56 48.75 56 62ZM78 44C78 61.67 66.81 76 53 76C39.19 76 28 61.67 28 44C28 26.33 39.19 12 53 12C66.81 12 78 26.33 78 44ZM93 57.5C93 69.93 84.49 80 74 80C63.51 80 55 69.93 55 57.5C55 45.07 63.51 35 74 35C84.49 35 93 45.07 93 57.5Z"
        case .drop: return "M50 8C72 20 92 42 92 62C92 92 8 92 8 62C8 42 28 20 50 8Z"
        }
    }
}
