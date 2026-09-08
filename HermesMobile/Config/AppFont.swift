import SwiftUI

enum AppFont {
    static func body(weight: Font.Weight? = nil) -> Font {
        system(.body, weight: weight)
    }

    static func subheadline(weight: Font.Weight? = nil) -> Font {
        system(.subheadline, weight: weight)
    }

    static func footnote(weight: Font.Weight? = nil) -> Font {
        system(.footnote, weight: weight)
    }

    static func caption(weight: Font.Weight? = nil) -> Font {
        system(.caption, weight: weight)
    }

    static func caption2(weight: Font.Weight? = nil) -> Font {
        system(.caption2, weight: weight)
    }

    static func headline(weight: Font.Weight? = nil) -> Font {
        system(.headline, weight: weight)
    }

    static func title(weight: Font.Weight? = nil) -> Font {
        system(.title, weight: weight)
    }

    static func title3(weight: Font.Weight? = nil) -> Font {
        system(.title3, weight: weight)
    }

    static func mono(style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> Font {
        system(style, design: .monospaced, weight: weight)
    }

    private static func system(
        _ style: Font.TextStyle,
        design: Font.Design = .default,
        weight: Font.Weight? = nil
    ) -> Font {
        .system(style, design: design, weight: weight)
    }
}
