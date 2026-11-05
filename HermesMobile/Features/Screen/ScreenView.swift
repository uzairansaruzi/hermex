import SwiftUI
import UIKit

/// A bot's Screen (#1567): the picture, who controls it, and the ways to take and return control.
/// It stays dumb: `ScreenSession` owns the state, and the session streams only while this is on
/// screen with the app not in the background.
struct ScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var session: ScreenSession
    @State private var isTyping = false
    @State private var isConfirmingForce = false
    @State private var isConfirmingStop = false
    @State private var isConfirmingRemove = false
    @State private var isConfirmingRestart = false
    /// Direct touch or the trackpad panel, remembered per server.
    @AppStorage private var usesTrackpad: Bool
    /// Tells the entries the host has no screen at all, so they hide.
    private let onUnavailable: () -> Void

    init(profile: String, title: String, server: URL, connection: BotConnection, removesFromItsProfile: Bool = false,
         onUnavailable: @escaping () -> Void) {
        self.onUnavailable = onUnavailable
        var options = ScreenSession.Options()
        options.removesFromItsProfile = removesFromItsProfile
        _session = State(initialValue: ScreenSession(
            profile: profile, title: title, server: server, client: BotClient(saved: connection, server: server), options: options))
        _usesTrackpad = AppStorage(wrappedValue: false, BotScreenSettings.trackpadKey(for: server))
    }

    private var isMine: Bool { session.control == .mine }
    /// In the largest text sizes the bar's text wraps out, so Hand Back moves to the bottom.
    private var movesHandBackToBottom: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.appGroupedCanvas))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .confirmationDialog("Remove the plugin from this host?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { session.removePlugin() }
                } message: {
                    Text("This computer's screen stops being available in Hermex. You can install it again from here.")
                }
        }
        .onAppear { session.open() }
        .onDisappear { session.leave() }
        .onChange(of: scenePhase) {
            // Control Center and banners (`.inactive`) keep the stream, as they keep the gateway.
            switch scenePhase {
            case .background: session.suspend()
            case .active: session.returnToForeground()
            default: break
            }
        }
        .onChange(of: NetworkPathMonitor.shared.changeCount) { session.networkDidChange() }
        .onChange(of: session.phase) { if session.phase == .unavailable { onUnavailable() } }
        .onChange(of: isMine) { if !isMine { isTyping = false } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Closing while holding would hand back, so the button says so. A hand-back that
            // failed offers the way out too, or a dead link would trap the user here.
            if isMine, !movesHandBackToBottom, session.notice != .handBackFailed {
                Button("Hand Back") { session.handBack() }
            } else {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("Screen").font(.headline)
                Group {
                    if session.source == .hostDesktop {
                        Text("This computer's real desktop")
                    } else {
                        Text("Bot desktop")
                    }
                }
                .font(.caption).foregroundStyle(.appSecondary)
            }
            .accessibilityElement(children: .combine)
        }
        if isMine {
            ToolbarItem(placement: .primaryAction) {
                Button { isTyping.toggle() } label: {
                    Label(isTyping ? "Hide Keyboard" : "Show Keyboard",
                          systemImage: isTyping ? "keyboard.chevron.compact.down" : "keyboard")
                }
            }
        } else if session.canRemovePlugin || (session.phase == .live && session.source == .botDesktop) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if session.source == .hostDesktop {
                        Button("Remove from This Host", systemImage: "trash", role: .destructive) { isConfirmingRemove = true }
                    } else {
                        Button("Stop Screen", systemImage: "stop", role: .destructive) { isConfirmingStop = true }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .connecting where session.frames.image == nil:
            ScreenNotice(title: "Connecting") { EmptyView() }
        case .connecting, .live, .reconnecting:
            live
        case .stopped:
            ScreenNotice(title: "Screen is off",
                         message: "Starting it uses about 1.5 GB of memory on the host. It stops after 30 minutes unused.") {
                Button("Start Screen") { session.start() }
                    .buttonStyle(.appProminent)
            }
        case .starting:
            ScreenNotice(title: "Starting the screen", message: "This takes a few seconds. You can leave and come back.") { EmptyView() }
        case .blocked(let reason):
            // The host's own words: too little memory, or a sandbox image with no desktop.
            ScreenNotice(title: "This screen can't start", detail: reason) { checkAgain }
        case .needsPackages(let command):
            ScreenNotice(title: "Install the desktop on this host",
                         message: command == nil
                             ? "This Linux host needs a few packages, and has no package manager Hermes knows."
                             : "This Linux host needs a few packages. Run this on the host:") {
                if let command {
                    Text(verbatim: command)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.appGroupedSurface), in: RoundedRectangle(cornerRadius: 12))
                    Button("Copy Command") { UIPasteboard.general.string = command }
                        .buttonStyle(.bordered)
                }
                checkAgain
            }
        case .unavailable:
            ScreenNotice(title: "No screen on this host", message: "This Hermes release doesn't offer a bot desktop.") { EmptyView() }
        case .pluginNotInstalled:
            ScreenNotice(title: "Show this computer's desktop?",
                         message: "Hermex installs the hermex-screen plugin on this host. Anyone with this server's login can then see and control everything on this computer.") {
                Button("Install Plugin") { session.installPlugin() }
                    .buttonStyle(.appProminent)
                staleTakeover
                noticeLine
            }
        case .pluginBusy:
            ScreenNotice(title: "Setting up this host", message: "This can take a moment. You can leave and come back.") { EmptyView() }
        case .pluginNeedsRestart(let canRestart):
            ScreenNotice(title: "Restart Hermes to finish",
                         message: canRestart ? "The plugin is installed. Restarting stops any running work on this host."
                             : "The plugin is installed. Restart the dashboard on the host, then check again.") {
                if canRestart {
                    Button("Restart Hermes") { isConfirmingRestart = true }
                        .buttonStyle(.appProminent)
                }
                checkAgain
                staleTakeover
                noticeLine
            }
            .confirmationDialog("Restart Hermes?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
                Button("Restart Hermes", role: .destructive) { session.restartForPlugin() }
            } message: {
                Text("Any running work on this host stops.")
            }
        case .pluginFailed:
            ScreenNotice(title: "The plugin didn't load",
                         message: "Hermes couldn't load hermex-screen, and restarting won't fix it. The dashboard log on the host says why.") {
                checkAgain
                staleTakeover
            }
        case .hostRefused(let reason):
            ScreenNotice(title: "This host can't show its screen", detail: reason) {
                checkAgain
                staleTakeover
                noticeLine
            }
        case .driverProblem(let reason):
            ScreenNotice(title: "The computer-use driver isn't ready", detail: reason) {
                Text(verbatim: "hermes computer-use doctor")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("Run this on the host to see what's wrong.")
                    .font(.footnote).foregroundStyle(.appSecondary)
                checkAgain
                staleTakeover
                noticeLine
            }
        case .permissionsMissing(let accessibility, let screenRecording):
            ScreenNotice(title: "Allow screen access",
                         message: "On this computer, in its privacy settings, turn on CuaDriver under:") {
                if accessibility { Text("Accessibility").font(.subheadline.weight(.medium)) }
                if screenRecording { Text("Screen Recording").font(.subheadline.weight(.medium)) }
                checkAgain
                staleTakeover
                noticeLine
            }
        case .failed:
            ScreenNotice(title: "Couldn't show the screen", message: "The connection to the screen was refused or broke.") { checkAgain }
        }
    }

    /// The picture with its controls: under it in portrait, and in landscape a side panel taking a
    /// third of the width when the trackpad is on. The picture keeps its place in both, so a
    /// rotation keeps its zoom and keyboard focus.
    private var live: some View {
        let showsTrackpad = isMine && usesTrackpad && !isTyping
        let isLandscape = verticalSizeClass == .compact
        let layout = isLandscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 0) {
                picture(takesTouches: isMine && !usesTrackpad)
                if isLandscape { bottomControls }
            }
            if showsTrackpad {
                if isLandscape {
                    trackpad.containerRelativeFrame(.horizontal) { width, _ in width / 3 }
                } else {
                    trackpad.frame(maxHeight: 220)
                }
            }
            if !isLandscape { bottomControls }
        }
    }

    private func picture(takesTouches: Bool) -> some View {
        ScreenCanvas(session: session, takesTouches: takesTouches, isControlling: isMine, isTyping: $isTyping)
            .opacity(session.phase == .reconnecting ? 0.45 : 1)
            .overlay(alignment: .top) {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.appMaterial(.regularMaterial), in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if session.isAskingStillThere {
                    stillThere
                }
            }
    }

    private var status: LocalizedStringKey {
        if session.phase == .reconnecting { return "Reconnecting" }
        switch session.control {
        case .mine: return "You have control"
        case .other: return "Another session holds control"
        case .bot: return "Bot in control"
        }
    }

    private var trackpad: some View {
        ZStack {
            ScreenTrackpad(session: session)
            Text("Swipe to move. Tap to click. Hold to drag.")
                .font(.footnote).foregroundStyle(.appSecondary)
                .multilineTextAlignment(.center).padding()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color(.appGroupedSurface))
    }

    private var stillThere: some View {
        VStack(spacing: 8) {
            Text("Still there?").font(.headline)
            Text("Control returns to the bot in 1 minute.").font(.subheadline).foregroundStyle(.appSecondary)
            Button("Keep Control") { session.keepControl() }
                .buttonStyle(.appProminent)
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.appMaterial(.regularMaterial), in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 8) {
            if let text = noticeText {
                Text(text).font(.footnote).foregroundStyle(.appSecondary).multilineTextAlignment(.center)
            }
            if session.phase == .reconnecting, isMine {
                Text("You still have control. The bot stays paused.")
                    .font(.footnote).foregroundStyle(.appSecondary).multilineTextAlignment(.center)
            }
            if session.control == .other {
                Text("The bot is blocked until someone hands back.")
                    .font(.footnote).foregroundStyle(.appSecondary).multilineTextAlignment(.center)
            }
            if session.isHostLocked {
                Group {
                    if session.canUnlockHost {
                        Text("Screen is locked. Take over and type this computer's password to unlock it.")
                    } else {
                        Text("Screen is locked. Unlock it at the computer.")
                    }
                }
                .font(.footnote).foregroundStyle(.appSecondary).multilineTextAlignment(.center)
            }
            if isMine {
                if isTyping { keyRow }
                else { touchModePicker }
                if movesHandBackToBottom {
                    Button("Hand Back") { session.handBack() }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            } else {
                Button { session.takeOver() } label: {
                    Text("Take Over").frame(maxWidth: .infinity)
                }
                .buttonStyle(.appProminent)
                .disabled(session.phase != .live || (session.isHostLocked && !session.canUnlockHost))
                if session.control == .other {
                    forceHandBackButton
                }
            }
        }
        .padding(12)
        .confirmationDialog("Stop this screen?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button("Stop Screen", role: .destructive) { session.stopScreen(force: session.control == .other) }
        } message: {
            if session.control == .other {
                Text("Someone holds this screen. They lose it at once, and everything open on it closes.")
            } else {
                Text("Everything open on it closes, and the bot's next action that needs it starts it again.")
            }
        }
    }

    /// A takeover on a screen that isn't streaming: the bot stays blocked until someone ends it.
    /// In the largest text sizes the toolbar has no Hand Back, so it's here too.
    @ViewBuilder private var staleTakeover: some View {
        if session.control == .other {
            Text("Another session holds control, so the bot is blocked until someone hands back.")
                .font(.footnote).foregroundStyle(.appSecondary)
            forceHandBackButton
        } else if isMine, movesHandBackToBottom {
            Button("Hand Back") { session.handBack() }
                .buttonStyle(.bordered)
        }
    }

    private var forceHandBackButton: some View {
        Button("Hand Back (Force)") { isConfirmingForce = true }
            .buttonStyle(.bordered).tint(.red)
            .confirmationDialog("Hand back for whoever holds this screen?", isPresented: $isConfirmingForce, titleVisibility: .visible) {
                Button("Hand Back (Force)", role: .destructive) { session.forceHandBack() }
            } message: {
                Text("They lose control at once, and the bot carries on.")
            }
    }

    @ViewBuilder private var noticeLine: some View {
        if let text = noticeText {
            Text(text).font(.footnote).foregroundStyle(.appSecondary)
        }
    }

    private var noticeText: LocalizedStringKey? {
        switch session.notice {
        case .someoneTookOver: return "Someone else took over. You're watching now."
        case .handedBackAutomatically: return "Control went back to the bot after 15 minutes."
        case .returnedToBot: return "Control went back to the bot."
        case .takeOverFailed: return "Couldn't take over. Check the connection and try again."
        case .handBackFailed: return "Couldn't hand back, so the bot stays paused. You can try again from Bots."
        case .forceFailed: return "Couldn't hand back. Check the connection and try again."
        case .stopFailed: return "Couldn't stop the screen. Check the connection and try again."
        case .pluginActionFailed: return "That didn't work on the host. Check the connection and try again."
        case nil: return nil
        }
    }

    private var touchModePicker: some View {
        Picker("Touch mode", selection: $usesTrackpad) {
            Text("Touch").tag(false)
            Text("Trackpad").tag(true)
        }
        .pickerStyle(.segmented)
    }

    /// Esc, Tab, the modifiers and arrows. A modifier stays lit until the next key or click takes it.
    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("esc", label: "Escape") { session.press(.escape) }
                keyButton("tab", label: "Tab") { session.press(.tab) }
                modifierButton("ctrl", label: "Control", key: .control)
                modifierButton("opt", label: "Option", key: .option)
                modifierButton("cmd", label: "Command", key: .command)
                keyButton("←", label: "Left") { session.press(.left) }
                keyButton("↓", label: "Down") { session.press(.down) }
                keyButton("↑", label: "Up") { session.press(.up) }
                keyButton("→", label: "Right") { session.press(.right) }
            }
        }
    }

    private func keyButton(_ text: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text).font(.footnote.weight(.medium)).padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func modifierButton(_ text: String, label: LocalizedStringKey, key: ScreenKey) -> some View {
        let latched = session.latchedModifiers.contains(key)
        return Button { session.toggleModifier(key) } label: {
            Text(verbatim: text).font(.footnote.weight(.medium)).padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .tint(latched ? .accentColor : nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(latched ? .isSelected : [])
    }

    private var checkAgain: some View {
        Button("Check Again") { session.open() }
            .buttonStyle(.appProminent)
    }
}

/// One state with no picture: what happened and what can be done. Static text, never a spinner.
private struct ScreenNotice<Actions: View>: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    /// The host's words, which are never a catalog key.
    var detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.appSecondary)
            }
            if let detail {
                Text(verbatim: detail).font(.subheadline).foregroundStyle(.appSecondary)
            }
            actions.padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
