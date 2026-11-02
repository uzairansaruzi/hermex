// Open Bot Avatar (Dominik Scholz), MIT. See AvatarPath.swift for the upstream pin.
import Foundation

nonisolated struct BotAvatarRGB: Hashable, Sendable {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
    init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^#(?:[a-fA-F0-9]{3}|[a-fA-F0-9]{6})$", options: .regularExpression) != nil else { return nil }
        let digits = String(text.dropFirst())
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let n = UInt32(expanded, radix: 16) else { return nil }
        self.init(Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
    }
    var hex: String {
        String(
            format: "#%02x%02x%02x", Int(BotAvatarPose.clamp(r, 0, 255).rounded()), Int(BotAvatarPose.clamp(g, 0, 255).rounded()),
            Int(BotAvatarPose.clamp(b, 0, 255).rounded()))
    }
    func mix(_ other: Self, _ t: Double) -> Self { Self(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t) }
    func shade(_ t: Double) -> Self {
        let m = max(r, g, b)
        return mix(Self(r * 0.35 - (m - r) * 0.1, g * 0.35 - (m - g) * 0.1, b * 0.35 - (m - b) * 0.1), t)
    }
    func tint(_ t: Double) -> Self { mix(Self(255, 255, 255), t) }
    var luminance: Double {
        func ch(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }
    func contrast(_ other: Self) -> Double { (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05) }
    var autoEyeColor: Self {
        let dark = Self(20, 22, 34)
        let light = Self(250, 250, 255)
        return contrast(dark) >= contrast(light) ? dark : light
    }
}
