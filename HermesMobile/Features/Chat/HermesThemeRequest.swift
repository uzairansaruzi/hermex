import Foundation

/// `set_theme`'s requests to the window showing the session (#1727). A Hermex chat gets them on
/// a gateway Webapp, whose session policy gives the `gui` source the `desktop_ui` toolset;
/// `hermes serve` gives that toolset only to the Desktop's `desktop` platform. `theme.apply`
/// sets the app's light or dark mode and accent, as Settings > Appearance does, and answers with
/// what it applied; `theme.pick` asks for a picker card the phone doesn't have, so its answer
/// tells the agent to ask in the chat instead. Both are answered at once, without a tap. The answers are
/// read by the agent, so their text is English and stays out of the String Catalog.
enum HermesThemeRequest {
    static let methods: Set<String> = ["theme.apply", "theme.pick"]

    /// What one `theme.apply` changes, and its answer: the JSON text `set_theme` hands the model.
    struct Change: Equatable {
        enum Accent: Equatable {
            /// The theme's own accent: no pick.
            case themeOwn
            case hex(String)
        }

        /// Nil leaves the mode as it is.
        var theme: AppTheme?
        /// Nil leaves the accent as it is.
        var accent: Accent?
        var answer: String

        /// Writes the change where Settings > Appearance keeps it.
        func store(in defaults: UserDefaults) {
            if let theme { defaults.set(theme.rawValue, forKey: AppTheme.storageKey) }
            switch accent {
            case .themeOwn: defaults.removeObject(forKey: AppAppearanceSettings.accentHexKey)
            case .hex(let hex): defaults.set(hex, forKey: AppAppearanceSettings.accentHexKey)
            case nil: break
            }
        }
    }

    /// Desktop's swatch ids, each on Hermex's swatch of that colour (Settings' `AccentPicker`).
    /// `nous` is the default theme's own accent on Desktop, as `theme` is.
    private static let swatches: [String: String] = [
        "green": "#4CC96B", "cyan": "#30B8C4", "violet": "#7D7AFF",
        "pink": "#FF6FAE", "red": "#FF5C5C", "orange": "#FF9F3C"
    ]
    private static let themeAccents: Set<String> = ["nous", "theme"]
    /// The accent ids Hermex takes, for a refusal's `available`.
    private static let accentIDs = ["green", "cyan", "nous", "violet", "pink", "red", "orange", "theme"]

    /// `theme.apply {accent?, mode?, layout?}`. Like Desktop, it checks every value before
    /// applying any, so a refusal changes nothing and the agent can retry without the value.
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

    /// `theme.pick {picker}`'s answer: `said` reaches the agent as what the user said. A cancel
    /// would read as the user dismissing the card.
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
