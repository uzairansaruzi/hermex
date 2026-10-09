import PhotosUI
import SwiftUI
import HermexWatchRoot
import WatchShared

/// Reply controls for one session: type, speak, attach a photo, read the latest
/// reply aloud, and stop a run the watch started. Recording replaces the row
/// with a Cancel / Send panel so a voice note is never sent by accident.
///
/// Stays in the hierarchy in Always-On so a reply being read aloud keeps
/// playing when the wrist drops; only the controls hide.
struct WatchSpeakControls: View {
    @Bindable var model: WatchRootModel
    let session: WatchSessionSummary
    /// The latest assistant turn as words. `nil` disables Read aloud.
    var listenText: String?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var capture = WatchVoiceCapture()
    @State private var recorder = WatchVoiceNoteRecorder()
    @State private var speaker = WatchReplySpeaker()
    @State private var photoItem: PhotosPickerItem?
    @State private var isSendingPhoto = false
    @State private var isSendingText = false
    @State private var isStopping = false
    /// Cleared when the screen goes away, so a late microphone grant cannot
    /// start recording after Cancel is no longer on screen.
    @State private var voiceAttempt: UUID?
    @State private var voiceStartInFlight = false

    var body: some View {
        Group {
            if isLuminanceReduced {
                alwaysOnStatus
            } else {
                controls
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            guard model.offersReplyControls else {
                photoItem = nil
                return
            }
            Task { await sendPickedPhoto(item) }
        }
        .onChange(of: model.offersReplyControls) { _, allowed in
            guard !allowed else { return }
            voiceAttempt = nil
            photoItem = nil
            if capture.phase == .recording {
                recorder.cancel()
                capture.cancel()
            } else if isFailed {
                capture.markIdle()
            }
        }
        .onChange(of: recorder.elapsed) { _, elapsed in
            if capture.phase == .recording, elapsed >= WatchVoiceCapturePolicy.maximumDuration {
                Task { await finishVoice() }
            }
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            // A dimmed screen hides Cancel, so the microphone must not stay
            // open behind it, and a permission prompt must not start it later.
            if reduced {
                voiceAttempt = nil
                if capture.phase == .recording { cancelVoice() }
            }
        }
        .onChange(of: model.complicationRecordID) { _, id in
            guard id != nil else { return }
            Task { await startFromComplication() }
        }
        .onAppear {
            guard model.complicationRecordID != nil else { return }
            Task { await startFromComplication() }
        }
        .onDisappear {
            // Leaving the screen must not leave the microphone open, including
            // a start that is still waiting on the permission prompt.
            voiceAttempt = nil
            if capture.phase == .recording {
                recorder.cancel()
                capture.cancel()
            }
            speaker.stop()
        }
    }

    @ViewBuilder
    private var alwaysOnStatus: some View {
        if speaker.isSpeaking {
            Label("Reading reply", systemImage: "speaker.wave.2")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if model.activeRun(for: session) != nil {
                stopRunButton
            }

            // Above the controls, not below them: a caption under the icon row
            // falls off a 46mm screen, which is how a failed send came to look
            // like a permanent banner with no cause next to it.
            if model.offersReplyControls, case .failed(let code) = capture.phase {
                Label(failureCopy(code), systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Reply failed. \(failureCopy(code))")
            }

            if model.offersReplyControls {
                switch capture.phase {
                case .recording:
                    recordingPanel
                case .transcribing:
                    progressRow("Transcribing…")
                case .sending:
                    progressRow("Sending…")
                case .idle, .failed:
                    composer
                }
            } else {
                readOnlyReply
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            // A List TextField on watchOS never presents the keyboard. TextFieldLink
            // opens the system input (keyboard, scribble, dictation) and sends on Done.
            TextFieldLink(prompt: Text("Message")) {
                HStack(spacing: 6) {
                    if isSendingText {
                        ProgressView()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "keyboard")
                    }
                    Text(isSendingText ? "Sending…" : "Message")
                        .lineLimit(1)
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 28)
            } onSubmit: { text in
                Task { await send(text) }
            }
            // TextFieldLink has no "did open" callback; the tap that opens the
            // keyboard is the retry, so the old failure goes then.
            .simultaneousGesture(TapGesture().onEnded { beginAttempt() })
            // Same white capsule as the iPhone's Chat button.
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.white)
            .frame(maxWidth: .infinity)
            .disabled(!model.canMutate || isSendingText)
            .accessibilityLabel("Message")
            .accessibilityHint("Opens the keyboard. Hermex sends the message when you finish.")

            HStack(spacing: 6) {
                iconButton(
                    systemImage: "mic.fill",
                    accessibilityLabel: "Speak to Hermex",
                    hint: "Records up to \(WatchVoiceCapturePolicy.maximumDurationPhrase). You can cancel before it sends."
                ) {
                    Task { await startVoice() }
                }
                .disabled(!model.canMutate)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    iconLabel(systemImage: "photo", isBusy: isSendingPhoto)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(isSendingPhoto || !model.canMutate)
                .accessibilityLabel(isSendingPhoto ? "Sending photo" : "Send a photo")

                listenButton
            }
        }
    }

    /// Hermes keeps the reply on iPhone. Read aloud still runs on the watch.
    private var readOnlyReply: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replies stay on iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Replies stay on iPhone for this server.")
            listenButton
        }
    }

    /// Disabled rather than hidden when the latest turn has nothing to read.
    private var listenButton: some View {
        iconButton(
            systemImage: speaker.isSpeaking ? "stop.fill" : "speaker.wave.2.fill",
            accessibilityLabel: speaker.isSpeaking ? "Stop reading" : "Read reply aloud",
            hint: speaker.isSpeaking
                ? "Stops reading the reply."
                : (listenText == nil ? "No reply to read yet." : "Reads Hermes’s latest reply in this session.")
        ) {
            toggleReadAloud()
        }
        .disabled(listenText == nil && !speaker.isSpeaking)
    }

    private func toggleReadAloud() {
        if speaker.isSpeaking {
            speaker.stop()
            WatchHaptics.play(.stop)
        } else if let listenText, speaker.speak(listenText) {
            WatchHaptics.play(.start)
        } else {
            WatchHaptics.play(.failure)
        }
    }

    // MARK: Recording

    private var recordingPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(elapsedLabel)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("/ \(Self.clock(WatchVoiceCapturePolicy.maximumDuration))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording, \(elapsedLabel)")

            HStack(spacing: 6) {
                Button {
                    cancelVoice()
                } label: {
                    iconLabel(systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Cancel recording")
                .accessibilityHint("Discards the recording without sending it.")

                Button {
                    Task { await finishVoice() }
                } label: {
                    iconLabel(systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.red)
                .accessibilityLabel("Send recording")
                .accessibilityHint("Your iPhone transcribes it and sends the recording.")
            }
        }
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .frame(width: 20, height: 20)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var stopRunButton: some View {
        Button(role: .destructive) {
            Task {
                isStopping = true
                defer { isStopping = false }
                beginAttempt()
                if await model.stop(session) {
                    WatchHaptics.play(.stop)
                } else {
                    capture.fail(code: model.lastErrorCode ?? "stopFailed")
                    WatchHaptics.play(.failure)
                }
            }
        } label: {
            Label(isStopping ? "Stopping…" : "Stop run", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(isStopping)
    }

    // MARK: Building blocks

    private func iconButton(
        systemImage: String,
        accessibilityLabel: String,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            iconLabel(systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(hint ?? "")
    }

    private func iconLabel(systemImage: String, isBusy: Bool = false) -> some View {
        Group {
            if isBusy {
                ProgressView()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
    }

    private var elapsedLabel: String {
        Self.clock(recorder.elapsed)
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Capture-only codes first, then the model's own copy so a send, stop or
    /// voice failure reads the same sentence wherever it surfaces.
    private func failureCopy(_ code: String) -> String {
        switch code {
        case "tooShort": return "Too short. Hold a moment longer."
        case "tooLong": return "Clip was cut at \(WatchVoiceCapturePolicy.maximumDurationPhrase)."
        case "tooLarge": return "That note is too large. Try a shorter one."
        case "micDenied": return "Allow the microphone in Settings."
        case "photoFailed": return "Couldn’t send that photo."
        case "photoTooLarge": return "That photo is too large to send from Apple Watch."
        case "speechUnavailable": return "Couldn’t send that note."
        case "empty": return "Nothing to send."
        default: return WatchRootModel.errorCopy(for: code)
        }
    }

    /// Every reply attempt starts clean: the previous failure leaves the
    /// caption and stops the model from echoing it anywhere else.
    private func beginAttempt() {
        if isFailed { capture.markIdle() }
        model.clearReplyControlError()
    }

    // MARK: Voice

    /// A complication tap lands here. The recording panel replaces the
    /// controls, so Send is not the thing the tap itself does.
    private func startFromComplication() async {
        guard model.offersReplyControls else {
            _ = model.consumeComplicationRecording()
            return
        }
        guard model.consumeComplicationRecording() else { return }
        await startVoice()
    }

    private func startVoice() async {
        guard model.offersReplyControls else { return }
        guard WatchVoiceStartGate.shouldAcceptNewAttempt(startInFlight: voiceStartInFlight) else { return }
        guard capture.phase == .idle || isFailed else { return }
        voiceStartInFlight = true
        defer { voiceStartInFlight = false }
        let attempt = UUID()
        voiceAttempt = attempt
        speaker.stop()
        beginAttempt()
        do {
            try await recorder.begin {
                WatchVoiceStartGate.shouldBeginRecording(attempt: attempt, currentAttempt: voiceAttempt)
            }
            guard WatchVoiceStartGate.shouldBeginRecording(attempt: attempt, currentAttempt: voiceAttempt) else {
                recorder.cancel()
                return
            }
            capture.beginRecording()
            WatchHaptics.play(.start)
        } catch WatchSpeechError.abandoned {
            recorder.cancel()
        } catch {
            capture.fail(code: "micDenied")
            WatchHaptics.play(.failure)
        }
    }

    private func cancelVoice() {
        guard capture.phase == .recording else { return }
        recorder.cancel()
        capture.cancel()
        WatchHaptics.play(.directionDown)
    }

    private var isFailed: Bool {
        if case .failed = capture.phase { return true }
        return false
    }

    private func finishVoice() async {
        guard capture.phase == .recording else { return }
        guard let clip = recorder.finish(), capture.finishRecording(duration: clip.duration) else {
            recorder.cancel()
            if capture.phase != .failed(code: "tooShort") && capture.phase != .failed(code: "tooLong") {
                capture.fail(code: "tooShort")
            }
            WatchHaptics.play(.failure)
            return
        }
        await transcribeAndSend(clip: clip)
    }

    private func transcribeAndSend(clip: WatchVoiceNoteRecorder.Clip) async {
        guard model.offersReplyControls else {
            try? FileManager.default.removeItem(at: clip.url)
            capture.markIdle()
            return
        }
        do {
            let data = try Data(contentsOf: clip.url)
            try? FileManager.default.removeItem(at: clip.url)
            capture.markSending()
            if await model.sendVoiceNote(audio: data, filename: clip.url.lastPathComponent, to: session) != nil {
                WatchHaptics.play(.success)
                capture.markIdle()
                WatchWidgetSnapshotPublisher.publish(model)
            } else {
                capture.fail(code: model.lastErrorCode == "tooLarge" ? "tooLarge" : "sendRejected")
                WatchHaptics.play(.failure)
            }
        } catch WatchVoiceNoteValidationError.audioTooLarge {
            try? FileManager.default.removeItem(at: clip.url)
            capture.fail(code: "tooLarge")
            WatchHaptics.play(.failure)
        } catch {
            try? FileManager.default.removeItem(at: clip.url)
            capture.fail(code: "speechUnavailable")
            WatchHaptics.play(.failure)
        }
    }

    // MARK: Text and photo

    private func send(_ rawText: String) async {
        guard model.offersReplyControls else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingText else { return }
        isSendingText = true
        defer { isSendingText = false }
        beginAttempt()
        if await model.send(text: text, to: session) != nil {
            WatchHaptics.play(.success)
            WatchWidgetSnapshotPublisher.publish(model)
        } else {
            // A typed send used to be haptic-only here and surfaced as a banner
            // over Now instead of next to the composer that failed.
            capture.fail(code: model.lastErrorCode ?? "sendRejected")
            WatchHaptics.play(.failure)
        }
    }

    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        guard model.offersReplyControls else { return }
        isSendingPhoto = true
        defer {
            isSendingPhoto = false
            photoItem = nil
        }
        beginAttempt()
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = WatchImageThumbnail.jpeg(
                    from: data,
                    maxPixelSize: WatchImageThumbnail.sendMaxPixelSize,
                    maxBytes: WatchImageThumbnail.sendMaxBytes
                  )
            else {
                capture.fail(code: "photoFailed")
                WatchHaptics.play(.failure)
                return
            }
            if await model.sendPhoto(
                image: jpeg,
                filename: "watch-photo-\(Int(Date().timeIntervalSince1970)).jpg",
                caption: "",
                to: session
            ) != nil {
                WatchHaptics.play(.success)
                WatchWidgetSnapshotPublisher.publish(model)
            } else {
                capture.fail(code: model.lastErrorCode == "tooLarge" ? "photoTooLarge" : "photoFailed")
                WatchHaptics.play(.failure)
            }
        } catch {
            capture.fail(code: "photoFailed")
            WatchHaptics.play(.failure)
        }
    }
}

