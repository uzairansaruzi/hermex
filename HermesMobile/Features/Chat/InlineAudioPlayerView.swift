import AVFoundation
import SwiftUI

/// A compact, Telegram-style inline audio player used both in the chat bubble
/// and in the full-screen attachment preview. Bytes are fetched lazily via the
/// injected `load` closure — the same authenticated raw-file route the image
/// loader uses — then played with `AVAudioPlayer`. Starting one player pauses
/// any other that's currently playing (see `AudioAttachmentPlaybackCenter`).
struct InlineAudioPlayerView: View {
    /// Accessibility / labelling name for the clip (typically the file name).
    let title: String
    /// Lazily fetches the raw audio bytes; returns `nil` on failure.
    let load: () async -> Data?

    @State private var model = InlineAudioPlayerModel()

    var body: some View {
        HStack(spacing: 12) {
            controlButton

            VStack(alignment: .leading, spacing: 4) {
                if model.phase == .failed {
                    Text("Couldn't play this audio")
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    scrubber
                    timeRow
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
        .task {
            await model.loadIfNeeded(using: load)
        }
        .onDisappear {
            model.teardown()
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch model.phase {
        case .idle, .loading:
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                ProgressView().tint(Color.accentColor)
            }
            .frame(width: 40, height: 40)
            .accessibilityLabel(String(localized: "Loading audio"))

        case .ready:
            Button {
                model.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ZoraBrand.ink)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(
                model.isPlaying
                    ? String(localized: "Pause \(title)")
                    : String(localized: "Play \(title)")
            )

        case .failed:
            ZStack {
                Circle().fill(Color(.systemFill))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            .accessibilityLabel(String(localized: "Audio unavailable"))
        }
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { model.displayTime },
                set: { model.scrub(to: $0) }
            ),
            in: 0...max(model.duration, 0.01),
            onEditingChanged: { editing in
                model.setScrubbing(editing)
            }
        )
        .tint(Color.accentColor)
        .disabled(model.phase != .ready)
        .accessibilityLabel(String(localized: "Playback position for \(title)"))
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Text(AudioDurationFormatter.string(from: model.displayTime))
            Spacer(minLength: 8)
            Text(AudioDurationFormatter.string(from: model.duration))
        }
        .font(AppFont.caption2().monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// Coordinates "one clip at a time": when a player starts, it asks the center
/// to pause whichever player was previously active.
@MainActor
final class AudioAttachmentPlaybackCenter {
    static let shared = AudioAttachmentPlaybackCenter()

    private weak var active: InlineAudioPlayerModel?

    private init() {}

    func playbackWillBegin(for model: InlineAudioPlayerModel) {
        if let active, active !== model {
            active.pauseForExternalRequest()
        }
        active = model
    }
}

/// Tracks whether the composer is actively capturing microphone audio for voice
/// dictation. The inline player consults this before commandeering the shared
/// `AVAudioSession`: switching it to `.playback` mid-capture would tear down the
/// live recording engine and silently interrupt dictation.
@MainActor
final class ComposerAudioCaptureState {
    static let shared = ComposerAudioCaptureState()

    private(set) var isCapturing = false

    private init() {}

    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
    }
}

/// Drives a single `AVAudioPlayer`: lazy load, play/pause, a 0.2s progress
/// ticker, and scrubbing. Owned by `InlineAudioPlayerView` via `@State`.
@MainActor
@Observable
final class InlineAudioPlayerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var scrubTime: Double?

    /// The position shown by the scrubber/label: the dragged value while the
    /// user is scrubbing, otherwise the live playback time.
    var displayTime: Double { scrubTime ?? currentTime }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let delegateProxy = AudioPlayerDelegateProxy()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var didLoad = false

    func loadIfNeeded(using load: () async -> Data?) async {
        guard !didLoad else { return }
        didLoad = true
        phase = .loading

        let data = await load()

        // A cancelled `.task` (e.g. the row scrolled off-screen mid-load) surfaces
        // as a `nil` result here. Don't treat that as a real failure: reset so the
        // player can load again if the view reappears, instead of being stuck on
        // the error state forever.
        if Task.isCancelled {
            didLoad = false
            phase = .idle
            return
        }

        guard let data else {
            phase = .failed
            return
        }
        configurePlayer(with: data)
    }

    private func configurePlayer(with data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            delegateProxy.onFinish = { [weak self] in
                Task { @MainActor in self?.handlePlaybackFinished() }
            }
            delegateProxy.onDecodeError = { [weak self] in
                Task { @MainActor in self?.handleDecodeError() }
            }
            player.delegate = delegateProxy
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    func togglePlayPause() {
        guard phase == .ready, let player else { return }
        if isPlaying {
            pause()
        } else {
            AudioAttachmentPlaybackCenter.shared.playbackWillBegin(for: self)
            activateSession()
            if player.play() {
                isPlaying = true
                startTicker()
            }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        // Release the shared session on manual pause too, so an audio app we
        // interrupted (Spotify, Podcasts, …) is told it can resume instead of
        // staying blocked until the view disappears. If another clip takes over,
        // its `activateSession()` immediately reclaims the session.
        deactivateSession()
    }

    /// Invoked by the playback center when another clip takes over.
    func pauseForExternalRequest() {
        pause()
    }

    func scrub(to time: Double) {
        scrubTime = time
    }

    func setScrubbing(_ scrubbing: Bool) {
        if scrubbing {
            scrubTime = currentTime
        } else if let target = scrubTime {
            player?.currentTime = target
            currentTime = target
            scrubTime = nil
        }
    }

    /// Stops playback and releases the run-loop ticker. Called on disappear.
    func teardown() {
        pause()
        player?.currentTime = 0
        currentTime = 0
        deactivateSession()
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        stopTicker()
        currentTime = 0
        player?.currentTime = 0
        deactivateSession()
    }

    /// A file can pass the `AVAudioPlayer(data:)` initializer but still fail to
    /// decode once playback actually starts. Surface that as a failure instead of
    /// leaving a live-looking play button that does nothing when tapped.
    private func handleDecodeError() {
        isPlaying = false
        stopTicker()
        deactivateSession()
        phase = .failed
    }

    private func activateSession() {
        // If composer dictation is currently capturing the mic, leave the shared
        // session alone: switching it to `.playback` would tear down the live
        // recording engine. `.playAndRecord` already supports playback, so the
        // clip still plays through the active session.
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Releases the shared session once playback ends or the view disappears, so
    /// any audio app we interrupted on `activateSession()` is told it can resume
    /// (`.notifyOthersOnDeactivation`). Skipped while composer dictation owns the
    /// mic — same guard as activation. If another clip is still playing, iOS
    /// refuses to deactivate a session with running I/O and `try?` swallows it,
    /// so this never cuts off an active clip.
    private func deactivateSession() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        stopTicker()
        // `.common` so the timer keeps firing while the transcript is scrolling.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard scrubTime == nil, let player else { return }
        currentTime = player.currentTime
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    deinit {
        ticker?.invalidate()
    }
}

/// `AVAudioPlayerDelegate` is `@objc` and can't live on an `@Observable`
/// `@MainActor` class, so a tiny `NSObject` proxy forwards the finish callback.
private final class AudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    var onDecodeError: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onDecodeError?()
    }
}
