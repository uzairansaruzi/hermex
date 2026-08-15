#if DEBUG
import SwiftUI

/// Debug gallery for the plan surface (`--surface-gallery-page 11`), plus an
/// auto-toggling motion lab (`page 12`) that drives the expand/collapse cycle
/// on a timer so a screen recording captures the same reveal every run.
struct PlanTimelineGalleryView: View {
    var page: Int = 11

    var body: some View {
        if page == 12 {
            PlanMotionLabView()
        } else if page == 13 {
            PlanComposerDockView()
        } else if page == 15 {
            PlanComposerDockView(planLength: .long)
        } else if page == 20 {
            PlanComposerDockView(planLength: .veryLong)
        } else if page == 23 {
            PlanLiveStressView()
        } else {
            states
        }
    }

    private var states: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                specimen(
                    "COLLAPSED · IN PROGRESS",
                    "Default state. Ring fills as steps resolve.",
                    state: Self.midRun,
                    expanded: false
                )

                specimen(
                    "EXPANDED · IN PROGRESS",
                    "Two done, one running, two pending.",
                    state: Self.midRun,
                    expanded: true
                )

                specimen(
                    "EXPANDED · ALL COMPLETE",
                    "Pill swaps the ring for a check.",
                    state: Self.finished,
                    expanded: true
                )

                specimen(
                    "EXPANDED · WITH CANCELLED",
                    "Cancelled reads as resolved-but-not-done.",
                    state: Self.withCancelled,
                    expanded: true
                )

                specimen(
                    "EXPANDED · WRAPPED ROW",
                    "Long step wraps; sweep stands down, dimming carries it.",
                    state: Self.wrapped,
                    expanded: true
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func specimen(
        _ title: String,
        _ subtitle: String,
        state: TodoState,
        expanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Glass is a blur of what is behind it, so a specimen on a flat
            // background shows none of the effect. Backing each one with text
            // makes the frost and the specular edge legible.
            ZStack(alignment: .leading) {
                Text(Self.backdrop)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 6)

                PlanTimelineView(state: state, isExpanded: .constant(expanded))
            }
        }
    }

    private static let backdrop = "Transcript text sits behind the plan so the glass has something to refract — without a backdrop the blur and its specular edge are invisible."

    static let motionBackdrop = "The assistant's answer continues underneath the plan card. As the card expands over this text the glass blurs it, and the beam traces the card's edge while the plan is open."

    // MARK: - Fixtures

    static let midRun = TodoState(todos: [
        TodoItem(rawID: "1", content: "Review the project requirements", status: .completed),
        TodoItem(rawID: "2", content: "Sketch the initial approach", status: .completed),
        TodoItem(rawID: "3", content: "Build the first draft", status: .inProgress),
        TodoItem(rawID: "4", content: "Test the main workflow", status: .pending),
        TodoItem(rawID: "5", content: "Polish and deliver the result", status: .pending)
    ])

    static let finished = TodoState(todos: [
        TodoItem(rawID: "1", content: "Review the project requirements", status: .completed),
        TodoItem(rawID: "2", content: "Sketch the initial approach", status: .completed),
        TodoItem(rawID: "3", content: "Build the first draft", status: .completed),
        TodoItem(rawID: "4", content: "Test the main workflow", status: .completed),
        TodoItem(rawID: "5", content: "Polish and deliver the result", status: .completed)
    ])

    static let withCancelled = TodoState(todos: [
        TodoItem(rawID: "1", content: "Audit the palette tokens", status: .completed),
        TodoItem(rawID: "2", content: "Migrate the legacy renderer", status: .cancelled),
        TodoItem(rawID: "3", content: "Wire the settings toggle", status: .inProgress),
        TodoItem(rawID: "4", content: "Capture before/after renders", status: .pending)
    ])

    static let wrapped = TodoState(todos: [
        TodoItem(rawID: "1", content: "Trace the todo_state contract through streaming and cold load so the panel never disagrees with the agent", status: .completed),
        TodoItem(rawID: "2", content: "Reconcile snapshots by timestamp", status: .inProgress)
    ])

    /// A long plan, including wrapping rows. Agents routinely emit lists this
    /// size, and the expanded card used to grow until it ran off the top of the
    /// screen — carrying its own collapse control with it, so the plan could be
    /// opened but never closed.
    static let longRun = TodoState(todos: [
        TodoItem(rawID: "1", content: "Run update-smart startup recovery and checklist gates", status: .completed),
        TodoItem(rawID: "2", content: "Pin upstream and publish the pre-restart change brief", status: .completed),
        TodoItem(rawID: "3", content: "Start and monitor the transactional update service", status: .inProgress),
        TodoItem(rawID: "4", content: "Interpret receipts and report activation state", status: .pending),
        TodoItem(rawID: "5", content: "Reconcile the agent runtime against the running WebUI", status: .pending),
        TodoItem(rawID: "6", content: "Verify the gateway profile routes to the right model", status: .pending),
        TodoItem(rawID: "7", content: "Re-run the smoke suite against the restarted surfaces", status: .pending),
        TodoItem(rawID: "8", content: "Summarize what changed and what still needs a human", status: .pending)
    ])

    /// A plan long enough that it must scroll on any device, which is what
    /// proves the cap engages rather than merely fitting by luck.
    static let veryLongRun = TodoState(todos: (1...20).map { index in
        TodoItem(
            rawID: "\(index)",
            content: "Step \(index): a task description long enough to wrap well beyond two lines on a phone, prove the trailing ellipsis appears, and make sure one unusually detailed task cannot take over the plan card",
            status: index < 4 ? .completed : (index == 4 ? .inProgress : .pending)
        )
    })
}

/// Drives the plan card open and closed on a fixed cadence, and advances the
/// steps, so a screen recording captures the reveal and the per-row status
/// changes deterministically.
private struct PlanMotionLabView: View {
    @State private var isExpanded = true
    @State private var completedCount = 1

    private let steps = [
        "Review the project requirements",
        "Sketch the initial approach",
        "Build the first draft",
        "Test the main workflow",
        "Polish and deliver the result"
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("PLAN · MOTION LAB")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Spacer()

            // Stand-in transcript so the glass and the beam have a backdrop.
            Text(PlanTimelineGalleryView.motionBackdrop)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            PlanTimelineView(state: state, isExpanded: $isExpanded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
        }
        .task {
            // Advance a step, then toggle, on a loop. Slow enough that each
            // phase of the reveal is legible frame by frame in the recording.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation { completedCount = (completedCount % steps.count) + 1 }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) { isExpanded.toggle() }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) { isExpanded.toggle() }
            }
        }
    }

    private var state: TodoState {
        TodoState(todos: steps.enumerated().map { index, content in
            let status: TodoItem.Status
            if index < completedCount {
                status = .completed
            } else if index == completedCount {
                status = .inProgress
            } else {
                status = .pending
            }
            return TodoItem(rawID: "\(index)", content: content, status: status)
        })
    }
}

/// The pill in situ: floating above a composer stand-in, which is the framing
/// that actually matters — the collapsed state is judged against the composer
/// below it, not against an empty page.
private struct PlanComposerDockView: View {
    @State private var isExpanded = false
    @State private var expandedInteractionPhase = 0
    /// Page 13 shows the five-step plan, 15 an eight-step one, 16 a twenty-step
    /// one. The long variants are the cases that exposed the expanded card
    /// growing past the top of the screen and taking its own collapse control
    /// with it.
    var planLength: PlanLength = .short

    enum PlanLength {
        case short, long, veryLong
    }
    @Environment(\.colorScheme) private var colorScheme
    /// The real height this fixture's dock sits in. Production publishes this
    /// from `ChatView`; nothing publishes it here, so without this the card
    /// fell back to the 844pt environment default — taller than it should be
    /// on some devices, shorter on others (iPhone 17 is 874pt) — and page 20
    /// rendered the 20-step card behind the composer stand-in. Gallery-only
    /// bug, but it made the long-plan pages untrustworthy as evidence.
    @State private var dockHeight: CGFloat = 0

    var body: some View {
        dockLayout
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { dockHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            dockHeight = height
                        }
                }
            }
            .environment(\.planDockHeight, dockHeight > 0 ? dockHeight : 844)
            // Auto-open shortly after launch so the expanded state — the whole
            // point of the long-plan pages — is capturable from the CLI, which
            // cannot tap.
            .task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) { isExpanded = true }
                if planLength == .veryLong {
                    // Exercise the same public row-control path the user taps:
                    // compact -> expanded -> compact. This leaves page 20 in
                    // the accepted resting state while catching gesture/state
                    // regressions in deterministic gallery recordings.
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    expandedInteractionPhase = 1
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    expandedInteractionPhase = 2
                }
            }
    }

    private var dockLayout: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Tell me your actual tasks and I'll organize them here.")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            HStack(spacing: 18) {
                ForEach(["doc.on.doc", "hand.thumbsup", "hand.thumbsdown", "arrow.turn.up.right"], id: \.self) { name in
                    Image(systemName: name)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            PlanTimelineView(
                state: planState,
                isExpanded: $isExpanded,
                debugRowInteractionPhase: expandedInteractionPhase
            )
            .padding(.bottom, 10)

            composerStandIn
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
        }
    }

    private var composerStandIn: some View {
        planComposerStandIn
    }

    private var planState: TodoState {
        switch planLength {
        case .short: PlanTimelineGalleryView.midRun
        case .long: PlanTimelineGalleryView.longRun
        case .veryLong: PlanTimelineGalleryView.veryLongRun
        }
    }

    private var planComposerStandIn: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
            Text("Work on Studio")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "mic")
                .font(.system(size: 17))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
/// Replays the field report's exact conditions (`--surface-gallery-page 23`):
/// a five-step plan with wrapping rows — *below* the old row-count gate, so
/// the pre-fix build rendered it with no scroll window at all — arriving
/// mid-"stream" with the keyboard raised, which squeezes the dock the same
/// way the screenshot showed. The plan opens expanded with no prior
/// measurement (the todo_state-arrives-mid-turn case), the text field grabs
/// focus to raise the keyboard, and the card must stay bounded, scrollable,
/// and dismissible by tapping its rows.
private struct PlanLiveStressView: View {
    @State private var isExpanded = true
    @State private var dockHeight: CGFloat = 0
    @FocusState private var composerFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""

    /// Five steps, matching the report's Boston-map plan: long enough to wrap,
    /// few enough that the old cap's `count <= 7` short path applied.
    private let state = TodoState(todos: [
        TodoItem(rawID: "1", content: "Find and validate public historical Boston shoreline and land-reclamation data, including archival maps, dated boundaries, and source provenance", status: .pending),
        TodoItem(rawID: "2", content: "Define dated stages, cartographic styling, labels, and sourcing treatment", status: .pending),
        TodoItem(rawID: "3", content: "Build the high-detail animated map from validated geographic data", status: .pending),
        TodoItem(rawID: "4", content: "Render GIF and MP4 deliverables", status: .pending),
        TodoItem(rawID: "5", content: "Inspect animation frames, metadata, timing, and export quality", status: .inProgress)
    ])

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("LIVE PLAN STRESS · keyboard raised, no prior measurement")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            Spacer()

            PlanTimelineView(state: state, isExpanded: $isExpanded, isLive: true)
                .padding(.horizontal)
                .padding(.bottom, 8)

            TextField("Ask anything… /commands", text: $draft)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .background(
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { dockHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in dockHeight = height }
            }
        }
        .environment(\.planDockHeight, dockHeight > 0 ? dockHeight : 844)
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            composerFocused = true
        }
    }
}
#endif
