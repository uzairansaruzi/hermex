import SwiftUI

/// The "Hold to speak" bar shown in voice-first composer mode.
/// Long press starts recording; short tap switches to text mode.
struct ComposerVoiceFirstBar: View {
    let isListening: Bool
    let silenceRemaining: TimeInterval
    let phase: ComposerVoiceFirstMode.Phase
    let onLongPressStart: () -> Void
    let onLongPressEnd: () -> Void
    let onTap: () -> Void

    @State private var isPressed = false
    @State private var longPressTriggered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background capsule
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(backgroundFill)
                    .frame(height: 40)

                // Silence timer progress overlay
                if isListening, phase == .hasTranscript {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: geo.size.width * silenceProgress)
                    }
                    .frame(height: 40)
                    .animation(.linear(duration: 0.1), value: silenceRemaining)
                }

                // Label
                HStack(spacing: 8) {
                    Image(systemName: isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isListening ? Color.accentColor : .secondary)
                        .symbolEffect(.variableColor.iterative, isActive: isListening)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(isListening ? .primary : .secondary)
                }
            }
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            longPressTriggered = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if isPressed {
                                    longPressTriggered = true
                                    onLongPressStart()
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        let wasLongPress = longPressTriggered
                        isPressed = false
                        longPressTriggered = false
                        if wasLongPress {
                            onLongPressEnd()
                        } else {
                            onTap()
                        }
                    }
            )

            // Hint text
            if !isListening {
                Text(String(localized: "Tap to switch to keyboard"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityLabel(isListening ? "Listening... tap to switch to text" : "Hold to speak, tap to type")
        .accessibilityAddTraits(.isButton)
    }

    private var statusText: String {
        switch phase {
        case .idle:
            return String(localized: "Hold to speak")
        case .listening:
            return String(localized: "Listening...")
        case .hasTranscript:
            let seconds = Int(ceil(silenceRemaining))
            return String(localized: "Sending in \(seconds)s...")
        case .sending:
            return String(localized: "Sending...")
        }
    }

    private var silenceProgress: CGFloat {
        guard silenceRemaining > 0 else { return 0 }
        let total = VoiceFirstModeSettings.defaultSilenceTimeout
        return CGFloat(1.0 - silenceRemaining / total)
    }

    private var backgroundFill: some ShapeStyle {
        if isListening {
            return AnyShapeStyle(Color.accentColor.opacity(0.08))
        } else if isPressed {
            return AnyShapeStyle(Color.primary.opacity(0.08))
        } else {
            return AnyShapeStyle(Color.primary.opacity(0.04))
        }
    }
}

/// The "switch to voice" bar shown in text composer mode when voice-first is enabled.
/// Same height/style as ComposerVoiceFirstBar for visual symmetry.
struct ComposerSwitchToVoiceBar: View {
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onTap) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .frame(height: 40)

                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)

                        Text(String(localized: "Switch to voice"))
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 40)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityLabel("Switch to voice input")
        }
    }
}
