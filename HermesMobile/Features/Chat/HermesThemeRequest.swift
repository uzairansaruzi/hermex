import Foundation

enum HermesThemeRequest {
    static let methods: Set<String> = ["theme.apply", "theme.pick"]

    struct Change: Equatable {
        enum Accent: Equatable {
            case themeOwn
            case hex(String)
        }

        var theme: AppTheme?
        var accent: Accent?
        var answer: String

        func store(in defaults: UserDefaults) {
            if let theme { defaults.set(theme.rawValue, forKey: AppTheme.storageKey) }
            switch accent {
            case .themeOwn: defaults.removeObject(forKey: AppAppearanceSettings.accentHexKey)
            case .hex(let hex): defaults.set(hex, forKey: AppAppearanceSettings.accentHexKey)
            case nil: break
            }
        }
    }

    private static let swatches: [String: String] = [
        "green": "#4CC96B", "cyan": "#30B8C4", "violet": "#7D7AFF",
        "pink": "#FF6FAE", "red": "#FF5C5C", "orange": "#FF9F3C"
    ]
    private static let themeAccents: Set<String> = ["nous", "theme"]
    private static let accentIDs = ["green", "cyan", "nous", "violet", "pink", "red", "orange", "theme"]

    static func apply(_ params: BotJSON) -> Change {
        let mode = params["mode"].text, accent = params["accent"].text
        var theme: AppTheme?
        if let mode {
            guard let known = AppTheme(rawValue: mode) else {
                return refusal("Unknown mode \"\(mode)\".", available: AppTheme.allCases.map(\.rawValue))
            }
            theme = known
        }
        var applied: [String: BotJSON] = theme.map { ["mode": .string($0.rawValue)] } ?? [:]
        var pick: Change.Accent?
        if let accent {
            if accent == "mono" { return refusal("Hermex has no mono accent.", available: accentIDs) }
            if themeAccents.contains(accent) {
                pick = .themeOwn
                applied["accent"] = .null
            } else if let hex = swatches[accent] {
                pick = .hex(hex)
                applied["accent"] = .string(accent)
            } else if accent.hasPrefix("#"), let hex = HeaderLogoColor.normalizedHex(accent) {
                pick = .hex(hex)
                applied["accent"] = .string("custom:" + hex)
            } else {
                return refusal("Unknown accent \"\(accent)\".", available: accentIDs)
            }
        }
        if params["layout"] != .null {
            return refusal("Hermex on iPhone has no layouts.", available: [])
        }
        return Change(theme: theme, accent: pick, answer: json(["success": .bool(true), "applied": .object(applied)]))
    }

    static func said(_ params: BotJSON) -> String {
        params["picker"].text == "accent"
            ? "Hermex, the iPhone app, has no picker card. Ask the user in the chat which accent they want "
                + "(green, cyan, violet, pink, red, orange or a hex colour), then call set_theme with it."
            : "Hermex, the iPhone app, has no layouts to pick."
    }

    private static func refusal(_ error: String, available: [String]) -> Change {
        Change(theme: nil, accent: nil, answer: json([
            "success": .bool(false), "error": .string(error), "available": .array(available.map(BotJSON.string))
        ]))
    }

    private static func json(_ fields: [String: BotJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(BotJSON.object(fields))) ?? Data(), as: UTF8.self)
    }
}
