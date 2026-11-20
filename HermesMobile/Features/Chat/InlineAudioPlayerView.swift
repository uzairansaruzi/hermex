import AVFoundation
import SwiftUI

struct InlineAudioPlayerView: View {
    let title: String
    let load: () async -> Data?
    var loadKey: Int? = 0
    var onOpen: (() -> Void)? = nil

    @State private var model = InlineAudioPlayerModel()
    @State private var admittedLoadKey: Int?

    var body: some View {
        HStack(spacing: 12) {
            controlButton

            VStack(alignment: .leading, spacing: 4) {
                if model.phase == .failed {
                    Text("Couldn't play this audio")
                        .font(AppFont.caption2())
                        .foregroundStyle(.appSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    scrubber
                    timeRow
                }
            }

            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.appSecondary)
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.chatTactile(.icon))
                .accessibilityLabel(String(localized: "Open attachment \(title)"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.appSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.25), lineWidth: 0.5)
        )
        .loadsOnceVisible(id: loadKey) { admittedLoadKey = $0 }
        .task(id: admittedLoadKey) {
            await model.loadIfNeeded(key: admittedLoadKey, using: load)
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
                        .foregroundStyle(.white)
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
                Circle().fill(Color(.appFill))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.appSecondary)
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
        .foregroundStyle(.appSecondary)
        .accessibilityHidden(true)
    }
}

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

@MainActor
final class ComposerAudioCaptureState {
    static let shared = ComposerAudioCaptureState()

    private(set) var isCapturing = false

    private init() {}

    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        if capturing { UsageReports.shared.record(.voiceInput) }
    }
}

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

    var displayTime: Double { scrubTime ?? currentTime }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let delegateProxy = AudioPlayerDelegateProxy()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var loadedKey: Int?
    @ObservationIgnored private var loadAttempt = 0

    func loadIfNeeded(key: Int? = 0, using load: () async -> Data?) async {
        guard let key, key != loadedKey, phase != .ready else { return }
        loadedKey = key
        loadAttempt += 1
        let attempt = loadAttempt
        phase = .loading

        let data = await load()
        guard attempt == loadAttempt else { return }

        if Task.isCancelled {
            loadedKey = nil
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
        deactivateSession()
    }

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

    private func handleDecodeError() {
        isPlaying = false
        stopTicker()
        deactivateSession()
        phase = .failed
    }

    private func activateSession() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func deactivateSession() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        stopTicker()
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
