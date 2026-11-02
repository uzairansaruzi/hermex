import Foundation
import SwiftUI

struct ComposerVoiceStatus: Equatable {
    let text: String
    let systemImage: String
    let isError: Bool
}

struct ComposerVoiceStatusView: View {
    let status: ComposerVoiceStatus
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Label(status.text, systemImage: status.systemImage)
                .font(.caption)
                .foregroundStyle(status.isError ? Color.red : Color.secondary)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
    }
}

/// The composer's bottom row while dictation runs, in place of the toolbar:
/// cancel, then the waveform and timer, then finish. The row has no Send: the
/// draft is locked until the words land, and Send comes back with the toolbar.
struct ComposerDictationRow: View {
    let voiceInput: ComposerVoiceInputController
    let circleSize: CGFloat
    let finishBackground: Color
    let finishForeground: Color

    var body: some View {
        HStack(spacing: 8) {
            Button(action: voiceInput.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel"))

            if let capture {
                HStack(spacing: 8) {
                    ComposerDictationWaveform(meter: voiceInput.levelMeter)
                    if let startedAt = voiceInput.captureStartedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(AudioDurationFormatter.string(from: context.date.timeIntervalSince(startedAt)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(capture)

                Button(action: voiceInput.stopKeepingTranscript) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: circleSize, height: circleSize)
                        .background(finishBackground)
                        .foregroundStyle(finishForeground)
                        .clipShape(Circle())
                }
                .buttonStyle(.chatTactile(.icon))
                .accessibilityLabel(Text("Stop voice input"))
            } else {
                Text(waitingLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: circleSize, height: circleSize)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }

        }
    }

    /// What the capture is called to VoiceOver, or nil while nothing is recording.
    private var capture: String? {
        switch voiceInput.state {
        case .listening: String(localized: "Listening...")
        case .serverListening: String(localized: "Recording...")
        case .idle, .requestingPermission, .transcribing: nil
        }
    }

    private var waitingLabel: String {
        voiceInput.state == .transcribing
            ? String(localized: "Transcribing...")
            : String(localized: "Requesting voice permissions...")
    }
}

/// Recent mic levels as bars, newest on the trailing edge. This view is the only
/// reader of `levels`, so each sample redraws these bars and nothing else. With
/// Reduce Motion the bars stay flat and it reads nothing at all.
struct ComposerDictationWaveform: View {
    let meter: ComposerVoiceLevelMeter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barSpacing: CGFloat = 5
    private static let barWidth: CGFloat = 2
    private static let minimumBarHeight: CGFloat = 2
    private static let restingLevel: Float = 0.2

    var body: some View {
        let levels = reduceMotion ? nil : meter.levels
        Canvas { context, size in
            let capacity = Int(size.width / Self.barSpacing)
            let count = levels.map { min($0.count, capacity) } ?? capacity
            for index in 0..<count {
                let level = levels.map { CGFloat($0[$0.count - count + index]) } ?? CGFloat(Self.restingLevel)
                let height = Self.minimumBarHeight + level * (size.height - Self.minimumBarHeight)
                let bar = CGRect(
                    x: size.width - CGFloat(count - index) * Self.barSpacing,
                    y: (size.height - height) / 2,
                    width: Self.barWidth,
                    height: height
                )
                context.opacity = 0.25 + 0.75 * level
                context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .foreground)
            }
        }
        .frame(height: 24)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

/// The composer mic. A quick **tap** toggles on-device dictation (unchanged); a
/// **press-and-hold** records a server-transcribed voice note, releasing to send
/// and sliding up to cancel. Both paths run through a single
/// `DragGesture(minimumDistance: 0)`: touch-down schedules a `DispatchWorkItem`
/// after the hold threshold, and a release before it fires cancels the item and
/// counts as a tap → dictation. See `pressGesture` for why timing beats composing
/// `LongPressGesture`/`TapGesture`.
struct ComposerVoiceControlButton: View {
    let isDisabled: Bool
    let color: Color
    let isRecordingVoiceNote: Bool
    var supportsVoiceNotes = true
    let onTap: () -> Void
    let onRecordingStart: () -> Void
    let onRecordingDragChanged: (CGFloat) -> Void
    let onRecordingEnd: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var didTriggerRecording = false
    @State private var holdWorkItem: DispatchWorkItem?

    @ViewBuilder var body: some View {
        if supportsVoiceNotes {
            label
                .gesture(pressGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    // VoiceOver synthesizes an activation rather than a real touch,
                    // so the gesture's tap path never fires for it.
                    if !isDisabled { onTap() }
                }
                .accessibilityAction(named: Text("Record voice note")) {
                    // VoiceOver can't hold-to-talk, so this starts recording; the
                    // recording bar then exposes "Stop and send" / "Cancel" actions.
                    onRecordingStart()
                }
        } else {
            Button {
                onTap()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    private var label: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .regular))
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color(.tertiarySystemFill)).frame(width: 34, height: 34))
            .foregroundStyle(isRecordingVoiceNote ? Color.red : color)
            .scaleEffect(reduceMotion ? 1 : (isRecordingVoiceNote ? 1.3 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isRecordingVoiceNote)
            .contentShape(Circle())
            .opacity(isDisabled && !isRecordingVoiceNote ? 0.4 : 1)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        isRecordingVoiceNote ? "mic.fill" : "mic"
    }

    private var accessibilityLabel: Text {
        Text(isRecordingVoiceNote ? String(localized: "Recording voice note") : String(localized: "Voice input"))
    }

    /// One `DragGesture(minimumDistance: 0)` distinguishes tap from hold by timing,
    /// which is far more reliable than composing `LongPressGesture`/`TapGesture`/
    /// `highPriorityGesture` (those let the press keep claiming the touch so the tap
    /// never wins). Touch-down schedules a delayed "start recording"; a release
    /// before the delay cancels it and counts as a tap → dictation. A perfectly
    /// still hold still records because the delay is timer-driven, not movement-driven.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    scheduleRecordingStart()
                }
                if isRecordingVoiceNote {
                    onRecordingDragChanged(value.translation.height)
                }
            }
            .onEnded { value in
                cancelScheduledRecordingStart()
                let triggered = didTriggerRecording
                isPressing = false
                didTriggerRecording = false

                if triggered {
                    onRecordingEnd(value.translation.height)
                } else if !isDisabled {
                    onTap()
                }
            }
    }

    private func scheduleRecordingStart() {
        didTriggerRecording = false
        let item = DispatchWorkItem {
            didTriggerRecording = true
            onRecordingStart()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledRecordingStart() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }
}

/// Telegram-style indicator shown above the composer while a voice note records:
/// a pulsing red dot, an `m:ss` timer, and a slide-to-cancel hint that turns red
/// once the cancel threshold is armed. Exposes explicit VoiceOver actions because
/// the hold-to-talk gesture isn't reachable with VoiceOver on.
struct ComposerVoiceRecordingBar: View {
    let elapsed: TimeInterval
    let isCancelArmed: Bool
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(isCancelArmed ? 0.4 : 1)

            Text(AudioDurationFormatter.string(from: elapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Label(
                isCancelArmed
                    ? String(localized: "Release to cancel")
                    : String(localized: "Slide up to cancel"),
                systemImage: isCancelArmed ? "xmark.circle.fill" : "chevron.up"
            )
            .font(.caption)
            .foregroundStyle(isCancelArmed ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording voice note, \(AudioDurationFormatter.string(from: elapsed))"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Stop and send"), onStop)
        .accessibilityAction(named: Text("Cancel recording"), onCancel)
    }
}
