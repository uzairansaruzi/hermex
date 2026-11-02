import SwiftUI

/// What a drawn face paints with, resolved for the current appearance.
struct BotDrawnPalette: Equatable {
    let bodyHex: String
    let body: Color
    let eyes: Color

    init(appearance: BotProfileAppearance, drawn: BotDrawnAvatar, name: String, scheme: ColorScheme) {
        let hex = BotAvatarPresentation(name: name, appearance: appearance).hex
        let adaptive = hex.lowercased() == BotAvatarColor.adaptiveHex
        bodyHex = adaptive ? (scheme == .dark ? "#ffffff" : "#000000") : hex
        body = Color.botBody(hex)
        eyes = drawn.eyeColor.flatMap(Color.init(botHex:)) ?? Color.botEyes(on: hex)
    }

    var bodyRGB: BotAvatarRGB { BotAvatarRGB(hex: bodyHex) ?? BotAvatarRGB(139, 92, 246) }
}

/// One drawn face at rest, in the rest tier: cached bitmaps for the body and a separate eye
/// layer, so a blink repaints two eyes and nothing else. Roll, lift and squash are transforms of
/// those layers. While a build is running it keeps showing what it last drew, or nothing, and a
/// definition that cannot be drawn shows the classic face.
struct BotAvatarEngineFace: View {
    let name: String
    let appearance: BotProfileAppearance
    let drawn: BotDrawnAvatar
    let size: CGFloat
    var pose: BotFacePose = .rest
    /// Runs the blink inside the eye layer; nil keeps the pose's own lid.
    var blink: BotBlinkSchedule?
    var store: BotAvatarRenderStore = .shared

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: BotAvatarRenderStore.Key, face: BotAvatarFace)?
    @State private var cannotDraw = false
    /// Eyes wait for the first body, so a face never shows as two floating eyes.
    @State private var bodyShown = false

    private var key: BotAvatarRenderStore.Key { BotAvatarRenderStore.key(drawn, expression: appearance.expression) }
    private var palette: BotDrawnPalette { BotDrawnPalette(appearance: appearance, drawn: drawn, name: name, scheme: scheme) }

    var body: some View {
        let face = store.cached(key) ?? loaded?.face
        ZStack {
            if let face, let bodyKey = bodyKey(face) {
                BotAvatarRestBodyLayer(rest: face.rest, key: bodyKey, layer: .behind)
                if bodyShown || face.volume.depth == 0 || BotAvatarBodyCache.shared.cached(bodyKey) != nil { eyes(face) }
                if face.hasFrontLayer { BotAvatarRestBodyLayer(rest: face.rest, key: bodyKey, layer: .front) }
            } else if cannotDraw {
                BotAvatarMarkView(name: name, appearance: appearance.withoutDrawnAvatar, size: size)
            }
        }
        .rotationEffect(.degrees(pose.roll))
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
        .offset(y: -size * pose.lift)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: key) {
            let requested = key
            let built = await store.face(for: requested)
            guard !Task.isCancelled else { return }
            guard let built else { cannotDraw = true; return }
            loaded = (requested, built); cannotDraw = false
            guard built.volume.depth > 0, let bodyKey = bodyKey(built) else { return }
            _ = await BotAvatarBodyCache.shared.value(for: bodyKey, rest: built.rest)
            guard !Task.isCancelled else { return }
            bodyShown = true
        }
    }

    private func bodyKey(_ face: BotAvatarFace) -> BotAvatarBodyCache.Key? {
        BotAvatarBodyCache.Key(volume: face.volume, color: palette.bodyRGB, appearance: scheme == .dark ? "dark" : "light",
                               pointSize: size, displayScale: displayScale)
    }

    @ViewBuilder private func eyes(_ face: BotAvatarFace) -> some View {
        if let blink {
            TimelineView(blink) { context in
                eyeLayer(face, lid: blink.isShut(at: context.date) ? BotFacePose.blink.lid : pose.lid)
            }
        } else {
            eyeLayer(face, lid: pose.lid)
        }
    }

    /// `pose` gaze is a fraction of the mark; the layer takes -1...1 of the travel its fit reserved.
    private func eyeLayer(_ face: BotAvatarFace, lid: Double) -> some View {
        BotAvatarEyeLayer(rest: face.rest, layout: face.layout, lid: lid,
                          gaze: AvatarPoint(pose.gazeX / BotAvatarEngineFace.gazeReach, pose.gazeY / BotAvatarEngineFace.gazeReach),
                          color: palette.eyes)
    }

    /// A `BotFacePose` gaze this far, as a fraction of the mark, is full eye travel.
    nonisolated static let gazeReach = 0.07
}

/// One drawn face in the live tier: the whole frame drawn from a pose, for a touch or the chat
/// title's work beat. Falls back to the rest tier until the face is built. It has no clock: the
/// caller redraws it only while something moves.
struct BotAvatarEngineLiveFace: View {
    let name: String
    let appearance: BotProfileAppearance
    let drawn: BotDrawnAvatar
    let size: CGFloat
    /// A look target, -1...1 on each axis.
    var gaze: BotAvatarGaze?
    var mood: BotAvatarMood = .idle
    var time: TimeInterval = 0
    var lid: Double = 1
    var store: BotAvatarRenderStore = .shared

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let face = store.cached(BotAvatarRenderStore.key(drawn, expression: appearance.expression)) {
            let palette = BotDrawnPalette(appearance: appearance, drawn: drawn, name: name, scheme: scheme)
            BotAvatarLiveView(volume: face.volume,
                              pose: BotAvatarPose.compute(seed: face.volume.seed, time: time, mood: .mood(mood), gaze: gaze, lid: lid),
                              layout: face.layout, bodyColor: palette.body, eyeColor: palette.eyes)
                .frame(width: size, height: size)
        } else {
            BotAvatarEngineFace(name: name, appearance: appearance, drawn: drawn, size: size)
        }
    }
}
