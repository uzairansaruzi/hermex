#if DEBUG
import SwiftUI

/// Debug-only Streaming Lab (issue #234): replays a canned markdown fixture
/// through the real display pipeline (`MarkdownRenderer(content:isStreaming:)`
/// → chunked streaming view → fade window) while the fade knobs are tuned
/// live via `StreamingTextFadeLab`. No server, deterministic content.
struct StreamingLabView: View {
    @State private var displayedContent = ""
    @State private var isStreaming = false
    @State private var replayID = 0
    @State private var followsTail = true
    // Surfaced here because the user setting silently disables every fade
    // knob below — invisible state the lab must make visible (see the #232
    // textSelection dead-cascade hunt).
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) private var isStreamedTextAnimationEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var chromeBackgroundRawValue: String?
    @AppStorage(ChatPaletteTemperature.storageKey) private var chromeTemperatureRawValue: String?

    @State private var wordsPerSecond = StreamingLabReplay.defaultWordsPerSecond
    @State private var fadeDuration = StreamingTextFadeLab.shared.fadeDuration
    @State private var glyphStagger = StreamingTextFadeLab.shared.glyphStagger
    @State private var maxStampLead = StreamingTextFadeLab.shared.maxStampLead

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    Divider()
                    transcript
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchorID)
                }
                .padding(16)
            }
            .onChange(of: displayedContent) { _, _ in
                guard followsTail else { return }
                proxy.scrollTo(Self.tailAnchorID, anchor: .bottom)
            }
        }
        .appSurfaceBackground(.canvas)
        .navigationTitle("Streaming Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: replayID) {
            await replayFixture()
        }
    }

    private static let tailAnchorID = "streaming-lab-tail"

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    replayID += 1
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    StreamingTextFadeLab.shared.reset()
                    fadeDuration = StreamingTextFadeDefaults.Baseline.fadeDuration
                    glyphStagger = StreamingTextFadeDefaults.Baseline.glyphStagger
                    maxStampLead = StreamingTextFadeDefaults.Baseline.maxStampLead
                } label: {
                    Label("Reset Knobs", systemImage: "slider.horizontal.2.arrow.trianglehead.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Toggle("Follow tail while streaming", isOn: $followsTail)
                .font(.subheadline)

            Toggle("Streamed text animation (user setting)", isOn: $isStreamedTextAnimationEnabled)
                .font(.subheadline)

            if !isStreamedTextAnimationEnabled {
                Text("Animation is off — the knobs below have no visible effect until it's re-enabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            knobSlider(
                title: "Stream speed",
                value: $wordsPerSecond,
                range: StreamingLabReplay.minWordsPerSecond...StreamingLabReplay.maxWordsPerSecond,
                display: String(format: "%.0f words/s", wordsPerSecond)
            )

            knobSlider(
                title: "fadeDuration",
                value: $fadeDuration,
                range: 0.05...1.0,
                display: String(format: "%.2f s", fadeDuration)
            )
            .onChange(of: fadeDuration) { _, newValue in
                StreamingTextFadeLab.shared.fadeDuration = newValue
            }

            knobSlider(
                title: "glyphStagger",
                value: $glyphStagger,
                range: 0...0.06,
                display: String(format: "%.0f ms", glyphStagger * 1000)
            )
            .onChange(of: glyphStagger) { _, newValue in
                StreamingTextFadeLab.shared.glyphStagger = newValue
            }

            knobSlider(
                title: "maxStampLead",
                value: $maxStampLead,
                range: 0...1.5,
                display: String(format: "%.2f s", maxStampLead)
            )
            .onChange(of: maxStampLead) { _, newValue in
                StreamingTextFadeLab.shared.maxStampLead = newValue
            }

            knobReadout
        }
    }

    private func knobSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
        }
    }

    /// Paste-ready values for `StreamingTextFadeDefaults` once a feel is
    /// chosen (the lab never persists anything across launches).
    private var knobReadout: some View {
        Text(
            """
            static let fadeDuration: TimeInterval = \(String(format: "%.3f", fadeDuration))
            static let glyphStagger: TimeInterval = \(String(format: "%.3f", glyphStagger))
            static let maxStampLead: TimeInterval = \(String(format: "%.3f", maxStampLead))
            """
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    ChatPalette.appChrome(
                        colorScheme: colorScheme,
                        backgroundRawValue: chromeBackgroundRawValue,
                        temperatureRawValue: chromeTemperatureRawValue
                    ).surface
                )
        )
    }

    private var transcript: some View {
        MarkdownRenderer(
            content: displayedContent,
            isStreaming: isStreaming,
            typographyRole: .assistantResponse
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Local word-cadence appender standing in for the server stream: reveals
    /// the fixture unit-by-unit at the production tick interval, with the
    /// speed slider scaling how many units each tick deposits.
    private func replayFixture() async {
        displayedContent = ""
        isStreaming = true

        let fixture = StreamingLabReplay.fixture
        let totalUnits = StreamingLabReplay.fixtureUnitCount
        var revealed = 0
        var carry = 0.0

        while revealed < totalUnits {
            try? await Task.sleep(for: .seconds(StreamingLabReplay.tickInterval))
            guard !Task.isCancelled else { return }

            (revealed, carry) = StreamingLabReplay.advance(
                revealed: revealed,
                carry: carry,
                wordsPerSecond: wordsPerSecond
            )
            revealed = min(revealed, totalUnits)
            displayedContent = StreamingLabReplay.prefix(of: fixture, unitCount: revealed)
        }

        // A cancelled replay must not flip the flag: on restart the new task
        // has already set `isStreaming = true` and this would end its fade.
        guard !Task.isCancelled else { return }
        isStreaming = false
    }
}

/// Deterministic transcript showcase for Chat Theme v2. It composes the real
/// production message rows and renderer without needing server credentials.
struct ChatThemeLabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ResponseFontStyle.storageKey) private var responseFontStyleRawValue = ResponseFontStyle.defaultValue.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !isCaptureMode {
                    appearanceControls
                }
                MessageBubbleView(message: Self.userMessage)
                ReasoningBlockView(text: Self.reasoningText)
                ToolCallCardView(toolCall: Self.toolCall)
                MessageBubbleView(message: Self.assistantMessage)
                MarkerMessageCardView(
                    kind: .contextCompaction,
                    content: Self.markerText
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(palette.chatBackground)
        .navigationTitle("Chat Theme Lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isCaptureMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--chat-theme-lab-capture")
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Background", selection: $backgroundStyleRawValue) {
                ForEach(ChatBackgroundStyle.allCases) { style in
                    Text(style.title).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Serif Responses", isOn: serifBinding)
                .font(AppFont.subheadline())
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var serifBinding: Binding<Bool> {
        Binding(
            get: { ResponseFontStyle.storedValue(responseFontStyleRawValue).usesSerif },
            set: { responseFontStyleRawValue = ($0 ? ResponseFontStyle.serif : .system).rawValue }
        )
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }

    private static let userMessage = ChatMessage(
        role: "user",
        content: "Show me a polished implementation summary with examples.",
        timestamp: 1_750_000_000,
        messageId: "chat-theme-lab-user"
    )

    private static let assistantMessage = ChatMessage(
        role: "assistant",
        content: """
        # Session polish

        The transcript now uses a **warm, low-chrome palette** with relaxed line spacing and `semantic tokens` throughout. Long-form responses stay comfortable to scan while compact status surfaces remain visually secondary.

        This specimen includes **strong emphasis**, *italic emphasis*, ~~strikethrough~~, `inline code`, and an [accent-colored link](https://get-hermes.ai/api-docs/) in running prose.

        ## Reading rhythm

        > Calm surfaces should make the response easier to read without making the interface feel ornamental.

        ### Lists and hierarchy

        - A compact unordered item
          - A nested item that still wraps naturally
        - A second item with **bold context**
        - [x] Completed transcript polish
        - [ ] Final design approval

        1. Inspect the rendered hierarchy
           1. Keep nested numbering readable
        2. Compare the same content across themes

        ---

        #### Table and data

        | Element | Treatment |
        | --- | --- |
        | Prose | Dynamic body type |
        | Code | Warm inset slab |
        | Cards | Strokeless surfaces |
        | Radius | 10 / 14 / 20 |

        ##### Swift example

        ```swift
        let palette = ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: .warm
        )
        ```

        ###### Python example

        ```python
        result = {"status": "ready", "tests": "green"}
        ```

        Display math remains supported alongside inline math such as $a^2 + b^2 = c^2$:

        $$E = mc^2$$

        Reference: https://get-hermes.ai
        """,
        timestamp: 1_750_000_020,
        messageId: "chat-theme-lab-assistant",
        turnTps: 42.7
    )

    private static let reasoningText = "Compared the transcript hierarchy, normalized the surfaces, and kept streaming behavior unchanged."

    private static let toolCall = ToolCall(
        id: "chat-theme-lab-tool",
        name: "read_file",
        preview: "Loaded MarkdownRenderer.swift",
        args: ["path": .string("HermesMobile/Features/Chat/MarkdownRenderer.swift")],
        duration: 0.8,
        isCompleted: true,
        startedAt: 1_750_000_010
    )

    private static let markerText = "[Context compaction] Earlier transcript context remains available through the session summary."
}

#Preview {
    NavigationStack {
        StreamingLabView()
    }
}
#endif
