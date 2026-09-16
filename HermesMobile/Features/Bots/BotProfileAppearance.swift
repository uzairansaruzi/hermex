import SwiftUI
import UIKit

/// Static Bot Mode presentation shared with Hermes Desktop. The raw metadata
/// dictionary remains the source of truth; this projection only edits the keys
/// Hermex owns on the Profile screen.
struct BotProfileAppearance: Equatable, Sendable {
    var title: String
    var shape: String?
    var color: String?
    var custom: Bool
    var imageKind: String?

    init(profile: BotProfile) { self.init(look: profile.look, fallbackTitle: profile.name) }

    /// Reads a look object directly, so the editor can rebuild its appearance from the
    /// look it last saved instead of the roster row it was opened with.
    init(look: [String: BotJSON], fallbackTitle: String) {
        let storedTitle = look["title"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = storedTitle.isEmpty ? fallbackTitle : storedTitle
        shape = look["shape"]?.text
        color = look["color"]?.text
        custom = look["custom"]?.flag == true || shape != nil || color != nil
        imageKind = look["imageKind"]?.text
    }

    /// Applies only the compatible static appearance fields while retaining
    /// Desktop-owned organization, groups, timestamps and future fields.
    func merging(into received: [String: BotJSON]) -> [String: BotJSON] {
        var result = received
        Self.set(title, key: "title", in: &result)
        if custom {
            result["custom"] = .bool(true)
            if let shape { result["shape"] = .string(shape) } else { result.removeValue(forKey: "shape") }
            if let color { result["color"] = .string(color) } else { result.removeValue(forKey: "color") }
            if let imageKind { result["imageKind"] = .string(imageKind) }
            else { result.removeValue(forKey: "imageKind") }
        } else {
            for key in ["custom", "shape", "color", "imageKind"] { result.removeValue(forKey: key) }
        }
        return result
    }

    private static func set(_ value: String, key: String, in result: inout [String: BotJSON]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { result.removeValue(forKey: key) }
        else { result[key] = .string(trimmed) }
    }
}

enum BotAvatarShape: String, CaseIterable, Identifiable, Sendable {
    case circle, blob, squircle, pill, triangle, hexagon, cloud, drop
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .circle: return String(localized: "Circle")
        case .blob: return String(localized: "Blob")
        case .squircle: return String(localized: "Squircle")
        case .pill: return String(localized: "Pill")
        case .triangle: return String(localized: "Triangle")
        case .hexagon: return String(localized: "Hexagon")
        case .cloud: return String(localized: "Cloud")
        case .drop: return String(localized: "Drop")
        }
    }
}

/// A static rendering of Desktop's classic shape vocabulary. It never animates,
/// so inbox scrolling and Reduce Motion behave identically.
struct BotAvatarMarkView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat

    private var presentation: BotAvatarPresentation {
        BotAvatarPresentation(name: name, appearance: appearance)
    }

    var body: some View {
        ZStack {
            BotAvatarBody(shape: presentation.shape)
                .fill(presentation.color)
            HStack(spacing: size * 0.1) {
                Capsule().fill(presentation.eyeColor).frame(width: size * 0.075, height: size * 0.22).rotationEffect(.degrees(-18))
                Capsule().fill(presentation.eyeColor).frame(width: size * 0.075, height: size * 0.22).rotationEffect(.degrees(-18))
            }
            .offset(x: size * 0.12, y: -size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An asset wins over the compatible static mark. The fallback now honors the
/// same shape and color fields the editor writes instead of inventing a letter tile.
struct BotAvatarView: View {
    let profile: BotProfile
    let avatar: UIImage?
    let size: CGFloat

    var body: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            BotAvatarMarkView(name: profile.id, appearance: BotProfileAppearance(profile: profile), size: size)
        }
    }
}

private struct BotAvatarPresentation {
    let shape: BotAvatarShape
    let color: Color
    let eyeColor: Color

    init(name: String, appearance: BotProfileAppearance) {
        if name.lowercased() == "default", !appearance.custom {
            shape = .squircle
            color = Color(botHex: "#8b5cf6") ?? .purple
            eyeColor = Color.botHexIsDark("#8b5cf6") ? .white.opacity(0.9) : .black.opacity(0.85)
            return
        }
        let hash = name.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let shapes = BotAvatarShape.allCases.filter { $0 != .blob }
        let colors = ["#8b5cf6", "#38bdf8", "#14b8a6", "#22c55e", "#f59e0b", "#f97316", "#ef4444", "#ec4899"]
        shape = appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) ?? shapes[Int(hash % UInt64(shapes.count))]
        let hex = appearance.color ?? colors[Int(hash % UInt64(colors.count))]
        color = Color(botHex: hex) ?? .purple
        eyeColor = Color.botHexIsDark(hex) ? .white.opacity(0.9) : .black.opacity(0.85)
    }
}

private struct BotAvatarBody: Shape {
    let shape: BotAvatarShape

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        switch shape {
        case .circle:
            return Path(ellipseIn: inset)
        case .squircle:
            return Path(roundedRect: inset, cornerRadius: rect.width * 0.28)
        case .pill:
            let pill = CGRect(x: inset.minX, y: rect.midY - rect.height * 0.27,
                              width: inset.width, height: rect.height * 0.54)
            return Path(roundedRect: pill, cornerRadius: pill.height / 2)
        case .triangle:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            path.closeSubpath()
            return path
        case .hexagon:
            var path = Path()
            let points = [
                CGPoint(x: rect.midX, y: inset.minY), CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.3),
                CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.7), CGPoint(x: rect.midX, y: inset.maxY),
                CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.7), CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.3)
            ]
            path.move(to: points[0]); for point in points.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
            return path
        case .cloud:
            var path = Path()
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.38,
                                       width: rect.width * 0.48, height: rect.height * 0.48))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.12,
                                       width: rect.width * 0.5, height: rect.height * 0.64))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.35,
                                       width: rect.width * 0.38, height: rect.height * 0.45))
            return path
        case .drop:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: inset.minY))
            path.addCurve(to: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.62),
                          control1: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.2),
                          control2: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.42))
            path.addCurve(to: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.62),
                          control1: CGPoint(x: inset.maxX, y: inset.maxY), control2: CGPoint(x: inset.minX, y: inset.maxY))
            path.addCurve(to: CGPoint(x: rect.midX, y: inset.minY),
                          control1: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.42),
                          control2: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.2))
            return path
        case .blob:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.17))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.2),
                          control1: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY),
                          control2: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.02))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.86),
                          control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.4),
                          control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.78),
                          control1: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY),
                          control2: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.17),
                          control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.6),
                          control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
            return path
        }
    }
}

extension Color {
    init?(botHex: String) {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#", let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255)
    }

    fileprivate static func botHexIsDark(_ botHex: String) -> Bool {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#", let rgb = UInt64(value.dropFirst(), radix: 16) else { return false }
        let red = Double((rgb >> 16) & 0xff)
        let green = Double((rgb >> 8) & 0xff)
        let blue = Double(rgb & 0xff)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 110
    }
}
