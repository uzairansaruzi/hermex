import SwiftUI

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

    /// Where a touch at `x` is along the track, 0 to 1. The thumb's center stops short of each end,
    /// so a finger on the thumb at either end reads as that end, and past it stays on the ladder.
    static func position(atX x: CGFloat, width: CGFloat) -> Double {
        let span = max(width - ThinkingSliderMetrics.inset * 2, 1)
        return min(max((x - ThinkingSliderMetrics.inset) / span, 0), 1)
    }

    /// The nearest level to a position along the track.
    func index(atPosition position: Double) -> Int {
        guard levels.count > 1 else { return 0 }
        return Int((position * Double(levels.count - 1)).rounded())
    }

    func position(of index: Int) -> Double {
        levels.count > 1 ? Double(index) / Double(levels.count - 1) : 0
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

/// Picks the chat's thinking level. A tap on the track or a label sends that level. A sideways drag
/// follows the finger with a tick per level and sends one change on release, and a vertical one is
/// left to the list. A chosen level shows at once, and a refused one falls back to what the chat holds.
/// VoiceOver adjusts it like a slider, and the largest text sizes get a plain list.
struct ThinkingControl: View {
    let selection: ComposerModelEffortSelection
    let isDisabled: Bool
    /// Holds the animation while something covers the control, such as All models.
    var isCovered = false
    let onCommit: (String) -> Void

    @AppStorage(ThinkingSliderLook.storageKey) private var look = ThinkingSliderLook.defaultLook
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @GestureState private var isDragging = false
    /// Where the finger is along the track, 0 to 1, during a drag.
    @State private var dragPosition: Double?
    @State private var lastTickIndex: Int?

    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: selection.effortOptions.map(\.id), current: selection.committedEffort)
    }

    /// The level to name: the finger's while one is down, else the chat's.
    private var shownIndex: Int? {
        guard isDragging, let dragPosition else { return ladder.currentIndex }
        return ladder.index(atPosition: dragPosition)
    }

    /// Where the thumb goes. With no level reported it rests at the bottom of the ladder.
    private var shownPosition: Double {
        if isDragging, let dragPosition { return dragPosition }
        return ladder.currentIndex.map(ladder.position(of:)) ?? 0
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
                // A look draws left to right and reads touches the same way, so its labels stay in
                // that order too, in right-to-left languages as well.
                VStack(spacing: 8) {
                    track
                    labels
                }
                .environment(\.layoutDirection, .leftToRight)
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
        shownIndex.map { ReasoningEffortOption.title(for: ladder.levels[$0]) } ?? String(localized: "Default")
    }

    /// The drag waits for movement and isn't high priority, so a vertical swipe that starts here
    /// still scrolls the list and moves the sheet.
    private var track: some View {
        ThinkingSliderTrack(look: look, level: shownPosition, followsFinger: isDragging, isPaused: isCovered)
            // A new look starts from fresh state, not another look's particles.
            .id(look)
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            send(ladder.index(atPosition: ThinkingLadder.position(atX: location.x, width: width)))
                        }
                        .gesture(dragGesture(width: width))
                }
            }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($isDragging) { value, dragging, _ in
                dragging = ThinkingLadder.isAdjustment(value.translation)
            }
            .onChanged { value in
                guard ThinkingLadder.isAdjustment(value.translation) else { return }
                let position = ThinkingLadder.position(atX: value.location.x, width: width)
                dragPosition = position
                let index = ladder.index(atPosition: position)
                if index != (lastTickIndex ?? ladder.currentIndex) {
                    ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                }
                lastTickIndex = index
            }
            .onEnded { value in
                dragPosition = nil
                lastTickIndex = nil
                guard ThinkingLadder.isAdjustment(value.translation) else { return }
                let position = ThinkingLadder.position(atX: value.location.x, width: width)
                if let level = ladder.commit(at: ladder.index(atPosition: position)) { onCommit(level) }
            }
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { index, level in
                Button { send(index) } label: {
                    Text(verbatim: ReasoningEffortOption.shortTitle(for: level))
                        .font(.caption2.weight(index == shownIndex ? .semibold : .regular))
                        .foregroundStyle(index == shownIndex ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func send(_ index: Int) {
        guard let level = ladder.commit(at: index) else { return }
        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        onCommit(level)
    }

    /// The largest text sizes: no track holds names that large, so every level is its own row.
    private var levelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking")
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { position, level in
                Button {
                    if let level = ladder.commit(at: position) { onCommit(level) }
                } label: {
                    HStack {
                        Text(verbatim: ReasoningEffortOption.title(for: level)).foregroundStyle(.primary)
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

/// One look, running. Used by the control and by the Settings picker. Capped at 60 frames a second so
/// a ProMotion screen doesn't double the work, and still under Reduce Motion or while the app is away.
struct ThinkingSliderTrack: View {
    let look: ThinkingSliderLook
    /// 0 to 1 along the track.
    let level: Double
    /// Moves the thumb with the finger instead of easing to it.
    let followsFinger: Bool
    /// Holds the animation for a cover the track can't see for itself.
    var isPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ThinkingSliderStore()
    /// False once a pushed page hides the track.
    @State private var isOnScreen = true

    var body: some View {
        let isStill = reduceMotion
        let isHeld = isStill || isPaused || !isOnScreen || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isHeld)) { timeline in
            Canvas { context, size in
                let frame = store.advance(
                    time: timeline.date.timeIntervalSinceReferenceDate, target: level,
                    followsFinger: followsFinger, size: size, isStill: isStill
                )
                var track = context
                track.clip(to: Path(
                    roundedRect: CGRect(origin: .zero, size: size), cornerRadius: look.cornerRadius, style: .continuous
                ))
                look.drawTrack(&track, frame, store)
                look.drawThumb(&context, frame)
            }
        }
        .frame(height: ThinkingSliderMetrics.height)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .accessibilityHidden(true)
    }
}
