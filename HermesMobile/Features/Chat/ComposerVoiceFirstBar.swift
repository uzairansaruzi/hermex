import SwiftUI

/// The "Hold to speak" bar shown in voice-first composer mode.
/// Long press starts recording; short tap switches to text mode.
/// Gestures while recording (during streaming):
///   - Swipe up: cancel recording
///   - Swipe down: steer (inject into current stream without interrupting)
///   - Release without swiping: interrupt (stop stream + new reply)
/// When not streaming, release = normal send, swipe up = cancel.
struct ComposerVoiceFirstBar: View {
    let isListening: Bool
    let isStreaming: Bool
    let silenceRemaining: TimeInterval
    let phase: ComposerVoiceFirstMode.Phase
    let onLongPressStart: () -> Void
    let onLongPressEnd: (ReleaseAction) -> Void
    let onTap: () -> Void

    enum ReleaseAction {
        case send       // Normal send (no active stream)
        case interrupt  // Stop stream + new reply (default during stream)
        case queue      // Wait for response to finish, then send as new turn
        case cancel     // Discard recording
    }

    @State private var isPressed = false
    @State private var longPressTriggered = false
    @State private var dragOffset: CGSize = .zero
    @State private var armedAction: ReleaseAction = .send
    /// Token to prevent double-tap race: asyncAfter validates it matches current gesture.
    @State private var gestureToken: UInt = 0

    /// Upward drag distance to arm cancel.
    private static let cancelThreshold: CGFloat = -60
    /// Downward drag distance to arm steer.
    private static let steerThreshold: CGFloat = 60

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background capsule
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(backgroundFill)
                    .frame(height: 44)

                // Label
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconColor)
                        .symbolEffect(.variableColor.iterative, isActive: isPressed && longPressTriggered && (armedAction == .send || armedAction == .interrupt))

                    Text(statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(textColor)
                }
            }
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed {
                            isPressed = true
                            longPressTriggered = false
                            armedAction = isStreaming ? .interrupt : .send
                            dragOffset = .zero
                            gestureToken &+= 1
                            let token = gestureToken
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                // Only trigger if this is still the same gesture sequence.
                                if isPressed, gestureToken == token {
                                    longPressTriggered = true
                                    onLongPressStart()
                                }
                            }
                        }
                        if longPressTriggered {
                            dragOffset = value.translation
                            armedAction = resolveAction(from: value.translation)
                        }
                    }
                    .onEnded { _ in
                        let wasLongPress = longPressTriggered
                        let action = armedAction
                        isPressed = false
                        longPressTriggered = false
                        armedAction = isStreaming ? .interrupt : .send
                        dragOffset = .zero

                        if wasLongPress {
                            onLongPressEnd(action)
                        } else {
                            onTap()
                        }
                    }
            )

            // Hint below the bar
            if !isPressed, !isListening {
                Text(String(localized: "Tap to switch to keyboard"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if isPressed, longPressTriggered {
                Text(hintText)
                    .font(.caption2)
                    .foregroundStyle(hintColor)
                    .animation(.easeInOut(duration: 0.15), value: armedAction)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityLabel(isListening ? "Listening" : "Hold to speak")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            // VoiceOver double-tap → switch to keyboard (same as short tap)
            onTap()
        }
        .accessibilityAction(named: String(localized: "Start Recording")) {
            onLongPressStart()
        }
        .accessibilityAction(named: String(localized: "Send Recording")) {
            onLongPressEnd(isStreaming ? .interrupt : .send)
        }
    }

    // MARK: - Gesture resolution

    private func resolveAction(from translation: CGSize) -> ReleaseAction {
        let dy = translation.height

        // Up swipe = cancel
        if dy < Self.cancelThreshold {
            return .cancel
        }

        // Down swipe = queue (only meaningful during streaming)
        if isStreaming, dy > Self.steerThreshold {
            return .queue
        }

        // Default: interrupt during streaming, send otherwise
        return isStreaming ? .interrupt : .send
    }

    // MARK: - Visual state

    private var iconName: String {
        switch armedAction {
        case .cancel:
            return "xmark.circle.fill"
        case .queue:
            return "text.badge.plus"
        case .interrupt:
            return isPressed && longPressTriggered ? "waveform" : "mic.fill"
        case .send:
            return isPressed && longPressTriggered ? "waveform" : "mic.fill"
        }
    }

    private var iconColor: Color {
        switch armedAction {
        case .cancel: return .red
        case .queue: return .orange
        case .interrupt: return isPressed && longPressTriggered ? .accentColor : .secondary
        case .send: return isPressed && longPressTriggered ? .accentColor : .secondary
        }
    }

    private var textColor: Color {
        switch armedAction {
        case .cancel: return .red
        case .queue: return .orange
        case .interrupt: return .primary
        case .send: return isPressed && longPressTriggered ? .primary : .secondary
        }
    }

    private var statusText: String {
        if isPressed && longPressTriggered {
            switch armedAction {
            case .cancel:
                return String(localized: "Release to cancel")
            case .queue:
                return String(localized: "↓ Release to queue")
            case .interrupt:
                return String(localized: "Listening… release to send")
            case .send:
                return String(localized: "Listening…")
            }
        }
        // Not pressed — show phase status
        switch phase {
        case .idle:
            return String(localized: "Hold to speak")
        case .listening:
            return String(localized: "Transcribing…")
        case .hasTranscript:
            let seconds = Int(ceil(silenceRemaining))
            return String(localized: "Sending in \(seconds)s…")
        case .sending:
            return String(localized: "Sending…")
        }
    }

    private var hintText: String {
        switch armedAction {
        case .cancel:
            return String(localized: "↑ Release to cancel")
        case .queue:
            return String(localized: "Send after response completes")
        case .interrupt:
            return isStreaming
                ? String(localized: "↑ Cancel  ↓ Queue")
                : String(localized: "↑ Swipe up to cancel")
        case .send:
            return String(localized: "↑ Swipe up to cancel")
        }
    }

    private var hintColor: Color {
        switch armedAction {
        case .cancel: return .red
        case .queue: return .orange
        case .interrupt, .send: return .secondary
        }
    }

    private var backgroundFill: AnyShapeStyle {
        switch armedAction {
        case .cancel:
            return AnyShapeStyle(Color.red.opacity(0.1))
        case .queue:
            return AnyShapeStyle(Color.orange.opacity(0.1))
        case .interrupt:
            if isPressed && longPressTriggered {
                return AnyShapeStyle(Color.accentColor.opacity(0.08))
            } else {
                return AnyShapeStyle(Color.primary.opacity(0.04))
            }
        case .send:
            if isPressed && longPressTriggered {
                return AnyShapeStyle(Color.accentColor.opacity(0.08))
            } else {
                return AnyShapeStyle(Color.primary.opacity(0.04))
            }
        }
    }
}

/// The "switch to voice" bar shown in text composer mode when voice-first is enabled.
struct ComposerSwitchToVoiceBar: View {
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onTap) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .frame(height: 44)

                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)

                        Text(String(localized: "Switch to voice"))
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityLabel("Switch to voice input")
        }
    }
}
