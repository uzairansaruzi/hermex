import SwiftUI
import UIKit

/// A bot's Screen (#1567): the picture, what's happening to it, and the way out. It stays dumb:
/// `ScreenSession` owns the state, and the session streams only while this is on screen with the
/// app not in the background.
struct ScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ScreenSession
    /// Tells the entries the host has no screen at all, so they hide.
    private let onUnavailable: () -> Void

    init(profile: BotProfile, server: URL, connection: BotConnection, onUnavailable: @escaping () -> Void) {
        self.onUnavailable = onUnavailable
        _session = State(initialValue: ScreenSession(
            profile: profile.id, client: BotClient(saved: connection, server: server)))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Screen").font(.headline)
                            Text("Bot desktop").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
        .onAppear { session.open() }
        .onDisappear { session.close() }
        .onChange(of: scenePhase) {
            // Control Center and banners (`.inactive`) keep the stream, as they keep the gateway.
            switch scenePhase {
            case .background: session.close()
            case .active where session.phase != .live: session.open()
            default: break
            }
        }
        .onChange(of: NetworkPathMonitor.shared.changeCount) { session.networkDidChange() }
        .onChange(of: session.phase) { if session.phase == .unavailable { onUnavailable() } }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .connecting where session.frames.image == nil:
            ScreenNotice(title: "Connecting") { EmptyView() }
        case .connecting, .live, .reconnecting:
            picture
        case .stopped:
            ScreenNotice(title: "Screen is off", message: "This bot's screen isn't running.") { checkAgain }
        case .unsupported:
            ScreenNotice(title: "No screen on this host", message: "This host can't run a bot desktop.") { EmptyView() }
        case .unavailable:
            ScreenNotice(title: "No screen on this host", message: "This Hermes release doesn't offer a bot desktop.") { EmptyView() }
        case .failed:
            ScreenNotice(title: "Couldn't show the screen", message: "The connection to the screen was refused or broke.") { checkAgain }
        }
    }

    private var picture: some View {
        ScreenFramebufferView(frames: session.frames)
            .opacity(session.phase == .reconnecting ? 0.45 : 1)
            .background(Color.black)
            .overlay(alignment: .top) {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
    }

    private var status: LocalizedStringKey {
        if session.phase == .reconnecting { return "Reconnecting" }
        return session.holder == .human ? "Someone has control" : "Bot in control"
    }

    private var checkAgain: some View {
        Button("Check Again") { session.open() }
            .buttonStyle(.borderedProminent)
    }
}

/// One state with no picture: what happened and what can be done. Static text, never a spinner.
private struct ScreenNotice<Actions: View>: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            actions.padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

/// The picture, in a layer `ScreenFrameStore` writes to directly, so a frame never runs SwiftUI.
/// It scales to fit and never asks the desktop to resize. VoiceOver reads it as one element.
struct ScreenFramebufferView: UIViewRepresentable {
    let frames: ScreenFrameStore

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.contentsGravity = .resizeAspect
        view.layer.magnificationFilter = .linear
        view.layer.minificationFilter = .trilinear
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "Bot's screen")
        view.accessibilityHint = String(localized: "VoiceOver can't read what's on this screen.")
        view.accessibilityTraits = .image
        frames.layer = view.layer
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if frames.layer !== view.layer { frames.layer = view.layer }
    }
}
