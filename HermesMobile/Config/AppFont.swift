import SwiftUI

/// Gemini-style typography scale: slightly larger than iOS defaults across
/// the board. Agent body gets the biggest bump; user text and labels are
/// proportionally smaller so the chat has a clear reading hierarchy.
enum AppFont {
    /// Agent message body — the primary reading size (bumped ~2pt).
    static func body(weight: Font.Weight? = nil) -> Font {
        .system(size: 18, weight: weight ?? .regular)
    }

    /// User message body — slightly smaller than agent so turns are
    /// visually distinct.
    static func userBody(weight: Font.Weight? = nil) -> Font {
        .system(size: 16, weight: weight ?? .regular)
    }

    static func callout(weight: Font.Weight? = nil) -> Font {
        .system(size: 16, weight: weight ?? .regular)
    }

    static func subheadline(weight: Font.Weight? = nil) -> Font {
        .system(size: 15, weight: weight ?? .regular)
    }

    static func footnote(weight: Font.Weight? = nil) -> Font {
        .system(size: 14, weight: weight ?? .regular)
    }

    static func caption(weight: Font.Weight? = nil) -> Font {
        .system(size: 13, weight: weight ?? .regular)
    }

    static func caption2(weight: Font.Weight? = nil) -> Font {
        .system(size: 12, weight: weight ?? .regular)
    }

    static func headline(weight: Font.Weight? = nil) -> Font {
        .system(size: 17, weight: weight ?? .semibold)
    }

    static func title(weight: Font.Weight? = nil) -> Font {
        .system(size: 28, weight: weight ?? .regular)
    }

    static func title2(weight: Font.Weight? = nil) -> Font {
        .system(size: 22, weight: weight ?? .regular)
    }

    static func title3(weight: Font.Weight? = nil) -> Font {
        .system(size: 20, weight: weight ?? .regular)
    }

    /// Composer inline controls — deliberately smaller to fit everything in
    /// the Liquid Glass bar without crowding.
    static func control(weight: Font.Weight? = nil) -> Font {
        .system(size: 12, weight: weight ?? .regular)
    }

    static func mono(style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> Font {
        .system(size: 14, design: .monospaced, weight: weight ?? .regular)
    }
}
