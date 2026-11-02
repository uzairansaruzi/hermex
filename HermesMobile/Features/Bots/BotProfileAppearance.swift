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
    /// A `BotAvatarExpression` raw value. Hermex-owned: Desktop keeps the key but renders its own eyes.
    var expression: String?
    /// The drawn avatar, when this bot has more than a flat classic shape. Hermex-owned, like `expression`.
    var drawn: BotDrawnAvatar? { didSet { storedDrawn = nil } }
    /// The value as the host stored it, until the user picks a face. A save writes it back as it
    /// was, so a newer build's fields, or a whole format this build can't read, are never lost.
    private var storedDrawn: BotJSON?

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
        expression = look["expression"]?.text
        if let stored = look[BotDrawnAvatar.lookKey] {
            drawn = BotDrawnAvatar(json: stored)
            storedDrawn = stored
        }
    }

    /// The classic face this bot falls back to when its drawn avatar cannot be drawn.
    var withoutDrawnAvatar: BotProfileAppearance {
        var classic = self
        classic.drawn = nil
        return classic
    }

    /// Applies only the compatible static appearance fields while retaining
    /// Desktop-owned organization, groups, timestamps and future fields.
    func merging(into received: [String: BotJSON]) -> [String: BotJSON] {
        var result = received
        Self.set(title, key: "title", in: &result)
        if let expression { result["expression"] = .string(expression) } else { result.removeValue(forKey: "expression") }
        if let storedDrawn { result[BotDrawnAvatar.lookKey] = storedDrawn }
        else if let drawn { result[BotDrawnAvatar.lookKey] = drawn.json }
        else { result.removeValue(forKey: BotDrawnAvatar.lookKey) }
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

/// The swatches the editor and the create sheet offer for a drawn face. The first,
/// stored as Desktop's `#ffffff`, is the adaptive one: white on a dark screen and
/// black on a light one, so it never disappears into the background.
struct BotAvatarColor: Identifiable {
    let hex: String
    let name: LocalizedStringResource
    var id: String { hex }
    var localizedName: String { String(localized: name) }
    /// What the swatch and the face paint for this entry.
    var swatch: Color { Color.botBody(hex) }

    static let adaptiveHex = "#ffffff"

    static let palette = [
        BotAvatarColor(hex: adaptiveHex, name: "Auto"), BotAvatarColor(hex: "#a9703d", name: "Brown"),
        BotAvatarColor(hex: "#ef4444", name: "Red"), BotAvatarColor(hex: "#f97316", name: "Orange"),
        BotAvatarColor(hex: "#f59e0b", name: "Amber"), BotAvatarColor(hex: "#22c55e", name: "Green"),
        BotAvatarColor(hex: "#14b8a6", name: "Teal"), BotAvatarColor(hex: "#38bdf8", name: "Blue"),
        BotAvatarColor(hex: "#8b5cf6", name: "Purple"), BotAvatarColor(hex: "#ec4899", name: "Pink"),
        BotAvatarColor(hex: "#8e8e93", name: "Gray")
    ]
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

/// The rest expression of a drawn face: eye size, lean and spacing, after Bloub's
/// measured catalogue (MIT, jeremy-prt/bloub). Values are in Bloub's units of body
/// radius and degrees; `BotAvatarMarkView` scales them onto the mark.
enum BotAvatarExpression: String, CaseIterable, Identifiable, Sendable {
    case neutral, attentive, surprised, excited, happy, laughing, angry, sad
    case scared, wary, confused, curious, proud, shy, bored, sleepy
    /// Open Bot Avatar's happy eyes: two arcs rather than capsules.
    case joyful
    var id: String { rawValue }

    /// Draws as a stroked arc instead of a capsule.
    nonisolated var isArc: Bool { self == .joyful }

    struct Eye: Equatable { let width: Double; let height: Double; let tilt: Double }
    struct Geometry: Equatable { let left: Eye; let right: Eye; let split: Double }

    /// An unknown or missing stored value reads as neutral rather than failing the row.
    nonisolated static func resolve(_ raw: String?) -> BotAvatarExpression { raw.flatMap(BotAvatarExpression.init(rawValue:)) ?? .neutral }

    nonisolated var geometry: Geometry {
        func pair(_ w: Double, _ h: Double, _ tilt: Double = 0, split: Double) -> Geometry {
            Geometry(left: Eye(width: w, height: h, tilt: tilt), right: Eye(width: w, height: h, tilt: -tilt), split: split)
        }
        switch self {
        case .neutral, .joyful: return pair(0.186, 0.412, split: 15.46)
        case .attentive: return pair(0.21, 0.44, split: 16)
        case .surprised: return pair(0.45, 0.47, split: 19)
        case .excited: return pair(0.4, 0.56, -10, split: 19.5)
        case .happy: return pair(0.27, 0.17, 14, split: 17)
        case .laughing: return pair(0.34, 0.13, 20, split: 18)
        case .angry: return pair(0.34, 0.15, 30, split: 17)
        case .sad: return pair(0.22, 0.4, -28, split: 16)
        case .scared: return pair(0.4, 0.6, split: 20.5)
        case .wary: return Geometry(left: Eye(width: 0.21, height: 0.4, tilt: 0), right: Eye(width: 0.22, height: 0.15, tilt: 0), split: 16)
        case .confused: return Geometry(left: Eye(width: 0.2, height: 0.44, tilt: -18), right: Eye(width: 0.28, height: 0.17, tilt: 14), split: 16.5)
        case .curious: return Geometry(left: Eye(width: 0.24, height: 0.46, tilt: -8), right: Eye(width: 0.2, height: 0.38, tilt: -8), split: 16.5)
        case .proud: return pair(0.3, 0.15, 18, split: 17)
        case .shy: return pair(0.17, 0.3, split: 14)
        case .bored: return pair(0.3, 0.12, split: 16)
        case .sleepy: return pair(0.2, 0.42 * 0.42, split: 16)
        }
    }

    var localizedName: String {
        switch self {
        case .neutral: return String(localized: "Neutral")
        case .attentive: return String(localized: "Attentive")
        case .surprised: return String(localized: "Surprised")
        case .excited: return String(localized: "Excited")
        case .happy: return String(localized: "Happy")
        case .laughing: return String(localized: "Laughing")
        case .angry: return String(localized: "Angry")
        case .sad: return String(localized: "Sad")
        case .scared: return String(localized: "Scared")
        case .wary: return String(localized: "Wary")
        case .confused: return String(localized: "Confused")
        case .curious: return String(localized: "Curious")
        case .proud: return String(localized: "Proud")
        case .shy: return String(localized: "Shy")
        case .bored: return String(localized: "Bored")
        case .sleepy: return String(localized: "Sleepy")
        case .joyful: return String(localized: "Joyful")
        }
    }
}

/// One frame of Desktop's classic shape vocabulary. It has no clock of its own:
/// `BotAnimatedFaceView` supplies the pose, and tile grids draw it at rest.
struct BotAvatarMarkView: View {
    let name: String
    let appearance: BotProfileAppearance
    let size: CGFloat
    var pose: BotFacePose = .rest

    private var presentation: BotAvatarPresentation {
        BotAvatarPresentation(name: name, appearance: appearance)
    }

    var body: some View {
        if let drawn = appearance.drawn {
            BotAvatarEngineFace(name: name, appearance: appearance, drawn: drawn, size: size, pose: pose)
        } else {
            classicFace
        }
    }

    private var classicFace: some View {
        ZStack {
            BotAvatarClassicBody(shape: presentation.shape)
                .fill(presentation.color)
            let expression = BotAvatarExpression.resolve(appearance.expression)
            let geometry = expression.geometry
            HStack(spacing: size * 0.1 * geometry.split / 15.46) {
                eye(geometry.left, arc: expression.isArc)
                eye(geometry.right, arc: expression.isArc)
            }
            .offset(x: size * (0.12 + pose.gazeX), y: size * (-0.08 + pose.gazeY))
        }
        .rotationEffect(.degrees(pose.roll))
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
        .offset(y: -size * pose.lift)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Bloub measures eyes against the body radius; the neutral eye maps onto the
    /// mark's original 0.075 x 0.22 capsule with its 18 degree lean.
    @ViewBuilder private func eye(_ eye: BotAvatarExpression.Eye, arc: Bool) -> some View {
        let width = size * 0.075 * eye.width / 0.186, height = size * 0.22 * eye.height / 0.412
        if arc {
            BotAvatarArcEye()
                .stroke(presentation.eyeColor, style: StrokeStyle(lineWidth: width * 0.6, lineCap: .round))
                .frame(width: width * 1.44, height: height * 0.52)
                .rotationEffect(.degrees(eye.tilt))
                .scaleEffect(y: pose.lid, anchor: .bottom)
        } else {
            Capsule().fill(presentation.eyeColor)
                .frame(width: width, height: height * pose.lid)
                .rotationEffect(.degrees(BotAvatarClassic.lean + eye.tilt))
        }
    }
}

/// The upward arc of a joyful classic eye.
private struct BotAvatarArcEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return path
    }
}

/// What a bot's chat title face shows for the current turn (#757). Waiting and failed
/// override the pinned expression, since a pin is only the resting face; every other
/// surface keeps the pin. Only `.working` moves beyond a blink.
enum BotTitleFace {
    case resting, working, waiting, failed

    /// The eyes that replace the pinned expression, or nil to keep it.
    var expression: BotAvatarExpression? {
        switch self {
        case .waiting: return .curious
        case .failed: return .sad
        case .resting, .working: return nil
        }
    }

    /// The motion for an active scene: only work sways (from `beatStart`); every other
    /// face just blinks, so a pending approval never runs the 15 fps beat.
    func motion(beatStart: Date) -> BotFaceMotion {
        self == .working ? .working(since: beatStart) : .idle
    }

    /// What VoiceOver adds after the bot's name; nil when the face shows no state.
    var accessibilityValue: String? {
        switch self {
        case .waiting: return String(localized: "Needs attention")
        case .failed: return String(localized: "Turn failed")
        case .resting, .working: return nil
        }
    }
}

/// A bot's chat title (#757): its face and name in one pill beside Back, and the way into the
/// bot's profile. The face shows the turn's state (`BotTitleFace`) and stays hidden from
/// VoiceOver, which hears the state as the pill's value instead.
struct BotChatTitlePill: View {
    let profile: BotProfile
    let avatar: UIImage?
    let motion: BotFaceMotion
    let face: BotTitleFace
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                BotAvatarView(profile: profile, avatar: avatar, size: 30, motion: motion, expression: face.expression)
                Text(profile.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
            }
            .modifier(BotChatTitlePillFallback())
        }
        .accessibilityLabel(profile.name)
        .accessibilityValue(face.accessibilityValue ?? "")
        .accessibilityHint(Text("Opens this bot’s profile."))
    }
}

/// Before iOS 26 the toolbar draws no glass of its own, so the pill supplies a material.
struct BotChatTitlePillFallback: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

/// A bot's chat's pill in `ChatView` (#1145): `BotChatTitlePill` over the chat's turn. It owns
/// the working face's beat (#776), so only the pill redraws as the turn moves: one 30 s sway
/// when work starts or the chat returns from the background mid-turn, then a still lean, and
/// no motion while the scene is not active.
struct HermesBotChatPill: View {
    let turn: HermesChatTurnCoordinator
    let onOpen: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var workingBeat = BotWorkingBeat()

    var body: some View {
        if let profile = turn.botProfile {
            let face = turn.titleFace
            BotChatTitlePill(
                profile: profile,
                avatar: turn.settings.avatars[profile.id],
                motion: scenePhase == .active ? face.motion(beatStart: workingBeat.start) : .still,
                face: face, onOpen: onOpen
            )
            .onChange(of: turn.botTurn) { workingBeat.observe(turn.botTurn, at: Date()) }
            // The background drops the socket, so the turn is seen again on return: a new beat.
            .onChange(of: scenePhase) { if scenePhase == .background { workingBeat.rearm() } }
        }
    }
}

extension BotProfileAppearance {
    /// The render store key of this bot's drawn avatar, if it has one.
    var renderKey: BotAvatarRenderStore.Key? {
        drawn.map { BotAvatarRenderStore.key($0, expression: expression) }
    }

    /// A finished bitmap of the drawn avatar for a synchronous caller; nil when there is none
    /// or it is not built yet, and the caller draws the classic face instead.
    func drawnStill(name: String, pointSize: CGFloat, scale: CGFloat, dark: Bool) -> UIImage? {
        guard let drawn, let key = renderKey else { return nil }
        let palette = BotDrawnPalette(appearance: self, drawn: drawn, name: name, scheme: dark ? .dark : .light)
        // The automatic eyes `Color.botEyes` draws everywhere else, flattened onto the body.
        let ink = Color.botHexIsDark(palette.bodyHex) ? BotAvatarRGB(255, 255, 255) : BotAvatarRGB(0, 0, 0)
        let eyes = drawn.eyeColor.flatMap(BotAvatarRGB.init(hex:)) ?? ink.mix(palette.bodyRGB, 0.12)
        return BotAvatarRenderStore.shared.stillImage(key, body: palette.bodyRGB, eyes: eyes, pointSize: pointSize, scale: scale)
    }
}

/// An asset wins over the compatible static mark. The fallback now honors the
/// same shape and color fields the editor writes instead of inventing a letter tile.
struct BotAvatarView: View {
    let profile: BotProfile
    let avatar: UIImage?
    let size: CGFloat
    /// Photos never move; a drawn face blinks unless the caller asks for a frozen frame.
    var motion: BotFaceMotion = .idle
    /// Replaces the pinned expression on a drawn face, for a state the title shows; photos ignore it.
    var expression: BotAvatarExpression? = nil
    /// Set inside `ImageRenderer`, which runs no tasks and paints no Canvas, so a drawn avatar
    /// not yet built shows its classic face instead of nothing.
    var renderingToImage = false

    var body: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if appearance.drawn != nil, renderingToImage {
            BotAvatarMarkView(name: profile.id, appearance: appearance.withoutDrawnAvatar, size: size)
        } else {
            BotAnimatedFaceView(name: profile.id, appearance: appearance, size: size, motion: motion)
        }
    }

    private var appearance: BotProfileAppearance {
        var appearance = BotProfileAppearance(profile: profile)
        if let expression { appearance.expression = expression.rawValue }
        return appearance
    }
}

struct BotAvatarPresentation {
    let shape: BotAvatarShape
    /// The stored or name-seeded `#rrggbb`, before an adaptive color resolves.
    let hex: String
    let color: Color
    let eyeColor: Color

    init(name: String, appearance: BotProfileAppearance) {
        if name.lowercased() == "default", !appearance.custom {
            shape = .squircle
            hex = "#8b5cf6"
            color = Color(botHex: "#8b5cf6") ?? .purple
            eyeColor = Color.botHexIsDark("#8b5cf6") ? .white.opacity(0.9) : .black.opacity(0.85)
            return
        }
        let hash = name.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let shapes = BotAvatarShape.allCases.filter { $0 != .blob }
        let colors = ["#8b5cf6", "#38bdf8", "#14b8a6", "#22c55e", "#f59e0b", "#f97316", "#ef4444", "#ec4899"]
        shape = appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) ?? shapes[Int(hash % UInt64(shapes.count))]
        hex = appearance.color ?? colors[Int(hash % UInt64(colors.count))]
        color = Color.botBody(hex)
        eyeColor = Color.botEyes(on: hex)
    }
}

/// A classic body from its stored path, scaled to the view.
private struct BotAvatarClassicBody: Shape {
    let shape: BotAvatarShape

    /// Circle, squircle and pill stay primitives: SwiftUI draws those far more cheaply than
    /// curves, and a list of faces redraws them on every blink.
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        switch shape {
        case .circle:
            return Path(ellipseIn: inset)
        case .squircle:
            return Path(roundedRect: inset, cornerRadius: rect.width * 0.28)
        case .pill:
            let pill = CGRect(x: inset.minX, y: rect.midY - rect.height * 0.27, width: inset.width, height: rect.height * 0.54)
            return Path(roundedRect: pill, cornerRadius: pill.height / 2)
        case .blob, .triangle, .hexagon, .cloud, .drop:
            return BotAvatarClassic.flatPath(shape).applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
                .offsetBy(dx: rect.minX, dy: rect.minY)
        }
    }
}

extension Color {
    /// The body color for a stored hex. Desktop's white is drawn adaptively here:
    /// white in dark appearance, black in light.
    static func botBody(_ hex: String) -> Color {
        if hex.lowercased() == BotAvatarColor.adaptiveHex {
            return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : .black })
        }
        return Color(botHex: hex) ?? .purple
    }

    /// Eyes that contrast with `botBody(hex)` in both appearances.
    static func botEyes(on hex: String) -> Color {
        if hex.lowercased() == BotAvatarColor.adaptiveHex {
            return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(0.9) })
        }
        return botHexIsDark(hex) ? .white.opacity(0.9) : .black.opacity(0.85)
    }

    init?(botHex: String) {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#", let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255)
    }

    static func botHexIsDark(_ botHex: String) -> Bool {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#", let rgb = UInt64(value.dropFirst(), radix: 16) else { return false }
        let red = Double((rgb >> 16) & 0xff)
        let green = Double((rgb >> 8) & 0xff)
        let blue = Double(rgb & 0xff)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 110
    }
}
