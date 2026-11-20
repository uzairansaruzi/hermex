import SwiftUI

@MainActor @Observable final class ThinkingLevelSender {
    private(set) var pendingLevel: String?
    private(set) var isSending = false
    @ObservationIgnored private let settleDelay: Duration

    init(settleDelay: Duration = .milliseconds(250)) {
        self.settleDelay = settleDelay
    }

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
            if !isSending, pendingLevel == sent { pendingLevel = nil }
        }
    }
}

struct ThinkingLadder: Equatable {
    let levels: [String]
    let currentIndex: Int?

    init(levels: [String], current: String?) {
        var levels = levels
        if let current, !levels.contains(current) { levels.append(current) }
        self.levels = levels
        currentIndex = current.flatMap(levels.firstIndex(of:))
    }

    static func position(atX x: CGFloat, width: CGFloat) -> Double {
        let span = max(width - ThinkingSliderMetrics.inset * 2, 1)
        return min(max((x - ThinkingSliderMetrics.inset) / span, 0), 1)
    }

    func index(atPosition position: Double) -> Int {
        guard levels.count > 1 else { return 0 }
        return Int((position * Double(levels.count - 1)).rounded())
    }

    func position(of index: Int) -> Double {
        levels.count > 1 ? Double(index) / Double(levels.count - 1) : 0
    }

    func commit(at index: Int) -> String? {
        guard levels.indices.contains(index), index != currentIndex else { return nil }
        return levels[index]
    }

    static func isAdjustment(_ movement: CGSize) -> Bool {
        abs(movement.width) >= abs(movement.height)
    }

    func adjusted(by step: Int) -> Int? {
        let next = currentIndex.map { $0 + step } ?? 0
        return levels.indices.contains(next) ? next : nil
    }
}

struct ThinkingControl: View {
    let selection: ComposerModelEffortSelection
    let isDisabled: Bool
    var isCovered = false
    let onCommit: (String) -> Void

    @AppStorage(ThinkingSliderLook.storageKey) private var look = ThinkingSliderLook.defaultLook
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var drag = ThinkingSliderDrag()

    private var ladder: ThinkingLadder {
        ThinkingLadder(levels: selection.effortOptions.map(\.id), current: selection.committedEffort)
    }

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
                VStack(spacing: 8) {
                    ThinkingInteractiveTrack(look: look, ladder: ladder, isPaused: isCovered, drag: $drag) { index in
                        if let level = ladder.commit(at: index) { onCommit(level) }
                    }
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
                        .font(AppFont.caption2(weight: index == shownIndex ? .semibold : .regular))
                        .foregroundStyle(index == shownIndex ? Color(.appText) : Color(.appTextSecondary))
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

    private var levelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking")
            ForEach(Array(ladder.levels.enumerated()), id: \.offset) { position, level in
                Button {
                    if let level = ladder.commit(at: position) { onCommit(level) }
                } label: {
                    HStack {
                        Text(verbatim: ReasoningEffortOption.title(for: level)).foregroundStyle(.appPrimary)
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

struct ThinkingSliderDrag: Equatable {
    private(set) var position: Double?
    private(set) var isLanded = false
    private var lastTickIndex: Int?

    mutating func move(to position: Double, on ladder: ThinkingLadder) -> Bool {
        self.position = position
        isLanded = false
        let index = ladder.index(atPosition: position)
        defer { lastTickIndex = index }
        return index != (lastTickIndex ?? ladder.currentIndex)
    }

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

struct ThinkingInteractiveTrack: View {
    let look: ThinkingSliderLook
    let ladder: ThinkingLadder
    var isPaused = false
    @Binding var drag: ThinkingSliderDrag
    let onSelect: (Int) -> Void

    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

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
            onMove(context.converter.localLocation.x)
            onEnd()
        case .cancelled, .failed: onCancel()
        default: break
        }
    }
}

struct ThinkingSliderTrack: View {
    let look: ThinkingSliderLook
    let level: Double
    let followsFinger: Bool
    var isPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ThinkingSliderStore()
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
