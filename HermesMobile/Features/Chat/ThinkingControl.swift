import SwiftUI

/// Sends Thinking levels one at a time, keeping the newest. The level shows at once and stays up a
/// moment past the host's answer, since the chat's own value reaches this sheet through the views
/// around it, an update later. Clearing on the answer flashes the old level. A refused level clears
/// at once, falling back to what the chat holds with the reason beside the row.
@MainActor @Observable final class ThinkingLevelSender {
    private(set) var pendingLevel: String?
    private(set) var isSending = false
    @ObservationIgnored private let settleDelay: Duration

    init(settleDelay: Duration = .milliseconds(250)) {
        self.settleDelay = settleDelay
    }

    /// A level asked for while another is out waits, and only the newest goes.
    func request(_ level: String, send: @escaping (String) async -> Bool) {
        pendingLevel = level
        guard !isSending else { return }
        isSending = true
        Task {
            var sent: String?
            var accepted = false
            while let next = pendingLevel, next != sent {
                sent = next
                accepted = await send(next)
            }
            isSending = false
            if accepted { try? await Task.sleep(for: settleDelay) }
            // Another request may have started while this one waited, and now owns the level.
            if !isSending, pendingLevel == sent { pendingLevel = nil }
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

    /// Whether a touch's first movement is adjusting the level. A mostly vertical one is the list
    /// scrolling, and must neither preview nor send a level from wherever the finger happened to be.
    static func isAdjustment(_ movement: CGSize) -> Bool {
        abs(movement.width) >= abs(movement.height)
    }

    /// VoiceOver's swipe: one level along, or nothing at either end. With no current level,
    /// a swipe starts from the bottom of the ladder.
    func adjusted(by step: Int) -> Int? {
        let next = currentIndex.map { $0 + step } ?? 0
        return levels.indices.contains(next) ? next : nil
    }
}

/// Picks the chat's thinking level. A tap on the track or a label sends that level. A sideways drag
/// follows the finger with a tick per level and sends one change on release, and a vertical swipe
/// scrolls the list instead. A chosen level shows at once, and a refused one falls back to what the chat holds.
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
    @State private var drag = ThinkingSliderDrag()

    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: selection.effortOptions.map(\.id), current: selection.committedEffort)
    }

    /// The level to name: the finger's while one is down, else the chat's.
    private var shownIndex: Int? {
        drag.position.map(ladder.index(atPosition:)) ?? ladder.currentIndex
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
                    ThinkingInteractiveTrack(look: look, ladder: ladder, isPaused: isCovered, drag: $drag) { index in
                        if let level = ladder.commit(at: index) { onCommit(level) }
                    }
                    // A new look starts from fresh state, not another look's particles.
                    .id(look)
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

/// A drag along a Thinking slider. It keeps only where the finger is, so the level it names always
/// comes from the ladder as it is now.
struct ThinkingSliderDrag: Equatable {
    /// 0 to 1 along the track, while a finger is down and for a moment after it lands on a new level.
    private(set) var position: Double?
    /// The finger is gone and `position` holds where it landed. The picked level reaches the ladder
    /// through the screen around the track, an update after this state changes, and for that update
    /// the thumb would otherwise jump back toward the old level.
    private(set) var isLanded = false
    private var lastTickIndex: Int?

    /// Moves the finger. True when it crossed onto another level, for a tick.
    mutating func move(to position: Double, on ladder: ThinkingLadder) -> Bool {
        self.position = position
        isLanded = false
        let index = ladder.index(atPosition: position)
        defer { lastTickIndex = index }
        return index != (lastTickIndex ?? ladder.currentIndex)
    }

    /// Lifts the finger, once. The level it landed on, unless that's the current one.
    mutating func end(on ladder: ThinkingLadder) -> Int? {
        guard let position, !isLanded else { return nil }
        let index = ladder.index(atPosition: position)
        guard index != ladder.currentIndex else {
            cancel()
            return nil
        }
        self.position = ladder.position(of: index)
        isLanded = true
        lastTickIndex = nil
        return index
    }

    mutating func cancel() {
        position = nil
        isLanded = false
        lastTickIndex = nil
    }
}

/// A look you can tap and drag, shared by the Thinking control and the Settings picker. A sideways
/// drag follows the finger with a tick per level and picks a level on release.
struct ThinkingInteractiveTrack: View {
    let look: ThinkingSliderLook
    let ladder: ThinkingLadder
    var isPaused = false
    @Binding var drag: ThinkingSliderDrag
    /// A level picked by a tap or a release. Never the current one.
    let onSelect: (Int) -> Void

    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    /// With no current level the thumb rests at the bottom of the ladder.
    private var shownPosition: Double {
        drag.position ?? ladder.currentIndex.map(ladder.position(of:)) ?? 0
    }

    var body: some View {
        ThinkingSliderTrack(look: look, level: shownPosition, followsFinger: drag.position != nil && !drag.isLanded, isPaused: isPaused)
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            select(ladder.index(atPosition: ThinkingLadder.position(atX: location.x, width: width)))
                        }
                        .gesture(ThinkingSidewaysPan(
                            onMove: { x in
                                if drag.move(to: ThinkingLadder.position(atX: x, width: width), on: ladder) {
                                    ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                                }
                            },
                            onEnd: {
                                if let index = drag.end(on: ladder) { onSelect(index) }
                            },
                            onCancel: { drag.cancel() }
                        ))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .task(id: drag.isLanded) {
                guard drag.isLanded else { return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { drag.cancel() }
            }
    }

    private func select(_ index: Int) {
        guard index != ladder.currentIndex else { return }
        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        onSelect(index)
    }
}

/// A pan that begins only if the finger first moves sideways, and otherwise fails at once so the list
/// or sheet around it scrolls. SwiftUI's `DragGesture` can't decline a touch like that: it holds the
/// touch whichever way the finger goes, which stops a swipe that starts on a slider from scrolling.
private struct ThinkingSidewaysPan: UIGestureRecognizerRepresentable {
    let onMove: (CGFloat) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return ThinkingLadder.isAdjustment(CGSize(width: velocity.x, height: velocity.y))
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onMove(context.converter.localLocation.x)
        case .ended:
            // The lift can land past the last movement sample, on another level.
            onMove(context.converter.localLocation.x)
            onEnd()
        case .cancelled, .failed: onCancel()
        default: break
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
