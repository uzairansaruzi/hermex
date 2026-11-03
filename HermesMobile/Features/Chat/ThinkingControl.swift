import SwiftUI

/// The Thinking looks under comparison on a phone (#1550). Once one is picked, delete the
/// others, this enum, and the switcher in `ModelSettingsSheet`.
enum ThinkingControlStyle: String, CaseIterable {
    case labelledTicks = "B"
    case segmented = "C"
    case warmBars = "D"
    case livingMeter = "E"

    static let storageKey = "composer.thinkingControlStyle"
}

/// Sends Thinking levels one at a time, keeping the newest. The level shows at once as `pendingLevel`
/// and clears when the host has answered: the chat's state then has it, or a refused level falls back
/// to what the chat still holds, with the reason beside the row.
@MainActor @Observable final class ThinkingLevelSender {
    private(set) var pendingLevel: String?
    private(set) var isSending = false

    /// A level asked for while another is out waits, and only the newest goes.
    func request(_ level: String, send: @escaping (String) async -> Bool) {
        pendingLevel = level
        guard !isSending else { return }
        isSending = true
        Task {
            var sent: String?
            while let next = pendingLevel, next != sent {
                sent = next
                _ = await send(next)
            }
            pendingLevel = nil
            isSending = false
        }
    }
}

/// The levels Model settings offers and where the chat is on them. The host's level stays on
/// the ladder even when the model's list doesn't name it, so a newer host's level still shows.
struct ThinkingLadder: Equatable {
    let levels: [String]
    let currentIndex: Int?

    init(levels: [String], current: String?) {
        var levels = levels
        if let current, !levels.contains(current) { levels.append(current) }
        self.levels = levels
        currentIndex = current.flatMap(levels.firstIndex(of:))
    }

    /// The nearest level to a touch at `x` along `width`, kept on the ladder when the finger
    /// runs past either end.
    func index(atX x: CGFloat, width: CGFloat) -> Int {
        guard levels.count > 1, width > 0 else { return 0 }
        let position = (x / width * CGFloat(levels.count - 1)).rounded()
        return min(max(Int(position), 0), levels.count - 1)
    }

    /// What a release at `index` sends: nothing when it lands on the current level.
    func commit(at index: Int) -> String? {
        guard levels.indices.contains(index), index != currentIndex else { return nil }
        return levels[index]
    }

    /// Whether a drag is adjusting the level. A mostly vertical one is the list scrolling, and
    /// must neither preview nor send a level from wherever the finger happened to be.
    static func isAdjustment(_ translation: CGSize) -> Bool {
        abs(translation.width) >= abs(translation.height)
    }

    /// VoiceOver's swipe: one level along, or nothing at either end. With no current level,
    /// a swipe starts from the bottom of the ladder.
    func adjusted(by step: Int) -> Int? {
        let next = currentIndex.map { $0 + step } ?? 0
        return levels.indices.contains(next) ? next : nil
    }
}

/// Picks the chat's thinking level. A tap sends that level. A sideways drag previews with a tick
/// per level and sends one change on release, and a vertical one is left to the list. The value
/// shows at once, and a refused one falls back to what the chat holds. VoiceOver adjusts it like a slider, and the largest text sizes get a plain list.
struct ThinkingControl: View {
    let selection: ComposerModelEffortSelection
    let isDisabled: Bool
    let onCommit: (String) -> Void

    @AppStorage(ThinkingControlStyle.storageKey) private var style = ThinkingControlStyle.warmBars
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isTouching = false
    @State private var previewIndex: Int?

    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: selection.effortOptions.map(\.id), current: selection.committedEffort)
    }

    /// The level to draw: the finger's while one is down, else the chat's.
    private var shownIndex: Int? {
        isTouching ? previewIndex ?? ladder.currentIndex : ladder.currentIndex
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            levelList
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Thinking")
                    Spacer(minLength: 8)
                    Text(verbatim: valueTitle).fontWeight(.semibold)
                }
                lookForStyle
            }
            .opacity(isDisabled ? 0.5 : 1)
            .allowsHitTesting(!isDisabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Thinking"))
            .accessibilityValue(Text(verbatim: valueTitle))
            .accessibilityAdjustableAction { direction in
                guard !isDisabled else { return }
                let next = ladder.adjusted(by: direction == .increment ? 1 : -1)
                if let next, let level = ladder.commit(at: next) { onCommit(level) }
            }
        }
    }

    private var valueTitle: String {
        shownIndex.map { title(ladder.levels[$0]) } ?? String(localized: "Default")
    }

    private func title(_ level: String) -> String {
        ReasoningEffortOption.title(for: level)
    }

    @ViewBuilder
    private var lookForStyle: some View {
        switch style {
        case .labelledTicks:
            draggable(height: 30) { LabelledTicksLook(index: shownIndex, count: ladder.levels.count) }
            tickLabels
        case .segmented:
            segments
        case .warmBars:
            draggable(height: 34) {
                ThinkingBarsLook(index: shownIndex, count: ladder.levels.count, isWarm: isTouching && !reduceMotion)
            }
        case .livingMeter:
            draggable(height: 24) {
                LivingMeterLook(fraction: fraction(shownIndex), reduceMotion: reduceMotion)
            }
        }
    }

    private func fraction(_ index: Int?) -> CGFloat {
        guard let index, ladder.levels.count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(ladder.levels.count - 1)
    }

    /// Every look that drags shares this: a tap on a level, or a sideways drag with a tick per
    /// level and one change on release. The drag waits for movement and isn't high priority, so a
    /// vertical swipe that starts here still scrolls the list and moves the sheet.
    private func draggable<Look: View>(height: CGFloat, @ViewBuilder look: @escaping () -> Look) -> some View {
        GeometryReader { proxy in
            look()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    let index = ladder.index(atX: location.x, width: proxy.size.width)
                    guard let level = ladder.commit(at: index) else { return }
                    ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    onCommit(level)
                }
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($isTouching) { value, touching, _ in
                            touching = ThinkingLadder.isAdjustment(value.translation)
                        }
                        .onChanged { value in
                            guard ThinkingLadder.isAdjustment(value.translation) else { return }
                            let index = ladder.index(atX: value.location.x, width: proxy.size.width)
                            guard index != previewIndex else { return }
                            if previewIndex != nil || index != ladder.currentIndex {
                                ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                            }
                            previewIndex = index
                        }
                        .onEnded { value in
                            previewIndex = nil
                            guard ThinkingLadder.isAdjustment(value.translation) else { return }
                            let index = ladder.index(atX: value.location.x, width: proxy.size.width)
                            if let level = ladder.commit(at: index) { onCommit(level) }
                        }
                )
        }
        .frame(height: height)
    }

    /// Every name fits up to five levels. Past that only the ends are named, and the header
    /// above names the current one.
    private var tickLabels: some View {
        let levels = ladder.levels
        return HStack(spacing: 0) {
            ForEach(Array(levels.enumerated()), id: \.element) { position, level in
                if levels.count <= 5 || position == 0 || position == levels.count - 1 {
                    Text(verbatim: title(level))
                        .fontWeight(position == shownIndex ? .semibold : .regular)
                        .foregroundStyle(position == shownIndex ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
                if position < levels.count - 1, levels.count <= 5 || position == 0 {
                    Spacer(minLength: 2)
                }
            }
        }
        .font(.caption2)
    }

    /// Four across, so the eight levels a Hermes host offers wrap to two rows and keep their names.
    private var segments: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: min(ladder.levels.count, 4)), spacing: 2) {
            ForEach(Array(ladder.levels.enumerated()), id: \.element) { position, level in
                Button {
                    if let level = ladder.commit(at: position) {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                        onCommit(level)
                    }
                } label: {
                    Text(verbatim: title(level))
                        .font(.footnote.weight(position == shownIndex ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            position == shownIndex ? Color(.systemGray3) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// The largest text sizes: no look holds a name that large, so every level is its own row.
    private var levelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking")
            ForEach(Array(ladder.levels.enumerated()), id: \.element) { position, level in
                Button {
                    if let level = ladder.commit(at: position) { onCommit(level) }
                } label: {
                    HStack {
                        Text(verbatim: title(level)).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if position == ladder.currentIndex {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityAddTraits(position == ladder.currentIndex ? .isSelected : [])
            }
        }
    }
}

/// B: a track with a thumb on the current level and a tick at each stop.
private struct LabelledTicksLook: View {
    let index: Int?
    let count: Int

    var body: some View {
        GeometryReader { proxy in
            let thumb: CGFloat = 24
            let usable = max(proxy.size.width - thumb, 1)
            let step = usable / CGFloat(max(count - 1, 1))
            let middle = proxy.size.height / 2

            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                    .frame(height: 6)
                    .padding(.horizontal, thumb / 2)
                if let index {
                    Capsule().fill(Color(.label))
                        .frame(width: step * CGFloat(index) + thumb / 2, height: 6)
                        .padding(.leading, thumb / 2)
                }
                ForEach(0..<count, id: \.self) { stop in
                    Rectangle().fill(Color(.systemGray))
                        .frame(width: 2, height: 10)
                        .offset(x: thumb / 2 - 1 + step * CGFloat(stop))
                }
                if let index {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(width: thumb, height: thumb)
                        .offset(x: step * CGFloat(index))
                }
            }
            .frame(height: proxy.size.height)
            .position(x: proxy.size.width / 2, y: middle)
        }
    }
}

/// D: bars that rise along the ladder, filled to the level. They warm up only while a finger is
/// on them, so nothing repaints at rest; Reduce Motion leaves them plain.
private struct ThinkingBarsLook: View {
    let index: Int?
    let count: Int
    let isWarm: Bool

    @State private var isBright = false

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<count, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill(bar))
                        .brightness(isWarm && isFilled(bar) ? (isBright ? 0.12 : -0.04) : 0)
                        .frame(height: proxy.size.height * (0.26 + 0.74 * CGFloat(bar) / CGFloat(max(count - 1, 1))))
                }
            }
            .frame(height: proxy.size.height, alignment: .bottom)
        }
        .animation(isWarm ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: isBright)
        .onChange(of: isWarm) { _, warm in isBright = warm }
    }

    private func isFilled(_ bar: Int) -> Bool {
        index.map { bar <= $0 } ?? false
    }

    private func fill(_ bar: Int) -> AnyShapeStyle {
        guard isFilled(bar) else { return AnyShapeStyle(Color(.tertiarySystemFill)) }
        guard isWarm else { return AnyShapeStyle(Color(.label)) }
        return AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
    }
}

/// E: a smooth track that glows and breathes for as long as it is on screen, faster and hotter
/// at higher levels. The only look that repaints at rest, so it needs the owner's exception to
/// the no-repaint rule to ship. Reduce Motion stills it.
private struct LivingMeterLook: View {
    let fraction: CGFloat
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                // A new period restarts the breath at the new speed.
                BreathingFill(period: 2.4 - 1.7 * Double(fraction), heat: fraction, reduceMotion: reduceMotion)
                    .id(fraction)
                    .frame(width: max(proxy.size.width * fraction, 12))
            }
            .frame(height: 12)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct BreathingFill: View {
    let period: Double
    let heat: CGFloat
    let reduceMotion: Bool

    @State private var isInhaled = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.blue, .purple, .orange], startPoint: .leading, endPoint: .trailing))
            .brightness(isInhaled ? 0.15 : -0.08)
            .shadow(color: .orange.opacity(isInhaled ? 0.3 + 0.5 * heat : 0.1), radius: isInhaled ? 3 + 7 * heat : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: period).repeatForever(autoreverses: true), value: isInhaled)
            .onAppear { isInhaled = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduced in isInhaled = !reduced }
    }
}
