import SwiftUI

@MainActor struct BotDesktopView: View {
    @State private var desktop: BotDesktopSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSceneCaptured) private var isSceneCaptured
    @State private var help = false
    @State private var stopConfirmation = false
    @State private var forceStopConfirmation = false
    @State private var takeoverConfirmation = false
    @State private var keyboard = false
    @State private var clipboard = false
    @State private var trackpad = false
    @State private var specialKeys = false
    @State private var stickyKeys: Set<Int> = []
    @State private var leaving = false
    @State private var offeredTakeover = false
    let profile: BotProfile
    let avatar: UIImage?
    let takeoverReason: String?

    init(server: URL, connection: BotConnection, profile: BotProfile, avatar: UIImage? = nil,
         session: BotDesktopSession? = nil, takeoverReason: String? = nil) {
        _desktop = State(initialValue: session ?? BotDesktopSession(server: server, connection: connection, profile: profile.id))
        self.profile = profile
        self.avatar = avatar
        self.takeoverReason = takeoverReason
    }

    private var name: String { BotProfileAppearance(profile: profile).title }
    private var obscured: Bool { desktop.controlsDesktop && (isSceneCaptured || scenePhase != .active) }
    private var live: Bool { desktop.phase == .live }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BotDesktopWebView(desktop: desktop, controlEnabled: live && desktop.controlsDesktop && !obscured,
                              trackpad: trackpad)
                .id(desktop.rendererRevision)
                .opacity(live && !obscured ? 1 : 0)
                .allowsHitTesting(live && !obscured)
                .accessibilityHidden(!live || obscured)
                .accessibilityLabel("Computer")
            if !live { statePanel }
            if obscured {
                Label("Screen hidden while recording", systemImage: "eye.slash")
                    .padding().multilineTextAlignment(.center)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topBar
                if live && desktop.someoneElseControls {
                    Text("Someone else is using this computer").font(.caption).padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                } else if live && !desktop.leaseReason.isEmpty && !obscured {
                    Text(verbatim: desktop.leaseReason).font(.caption).lineLimit(2).padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) {
            if live && !obscured { bottomBar.padding(.horizontal, 12).padding(.vertical, 6) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .overlay(alignment: .topLeading) {
            BotDesktopKeyboard(wantsFocus: keyboard && live && desktop.controlsDesktop && !obscured) { text in
                desktop.input("type", arguments: ["text": text])
                stickyKeys.removeAll()
            } key: { key in
                sendKey(key)
            }
            .frame(width: 2, height: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task { if scenePhase == .active { desktop.open(newPresentation: true) } }
        .onChange(of: desktop.phase) { _, phase in
            if phase == .live, let takeoverReason, !offeredTakeover {
                offeredTakeover = true
                if desktop.someoneElseControls { takeoverConfirmation = true }
                else if !desktop.controlsDesktop { desktop.takeControl(reason: takeoverReason) }
            }
            if phase != .live { resetInput() }
        }
        .onChange(of: desktop.controlsDesktop) { if !desktop.controlsDesktop { resetInput() } }
        .onChange(of: obscured) { if obscured { resetInput() } }
        .onChange(of: scenePhase) {
            if scenePhase == .background { desktop.close() }
            else if scenePhase == .active { desktop.open() }
        }
        .onDisappear { if !leaving { desktop.close() } }
        .sheet(isPresented: $help) { helpSheet }
        .confirmationDialog("Turn off the computer?", isPresented: $stopConfirmation, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                if desktop.someoneElseControls { forceStopConfirmation = true }
                else { desktop.turnOff(force: false) }
            }
        } message: {
            Text("Turning it off closes everything running on the computer.")
        }
        .confirmationDialog("Someone else is using this computer", isPresented: $forceStopConfirmation, titleVisibility: .visible) {
            Button("Stop Anyway", role: .destructive) { desktop.turnOff(force: true) }
        } message: {
            Text("Turning it off closes everything running on the computer.")
        }
        .confirmationDialog("Someone else is using this computer", isPresented: $takeoverConfirmation, titleVisibility: .visible) {
            Button("Take Back Control") { desktop.takeControl(reason: takeoverReason ?? "") }
        }
        .alert("Could not complete the computer action.", isPresented: Binding(
            get: { desktop.actionFailed }, set: { if !$0 { desktop.clearActionError() } }
        )) { Button("OK") { desktop.clearActionError() } }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            chromeButton("Back", symbol: "chevron.left") {
                guard !leaving else { return }
                leaving = true
                Task {
                    if await desktop.leave() { dismiss() }
                    else { leaving = false }
                }
            }
            Spacer(minLength: 0)
            BotAvatarView(profile: profile, avatar: avatar, size: 22, motion: .still)
            Text(verbatim: name).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            chromeButton("How to use the computer", symbol: "questionmark.circle") { help = true }
            if live && desktop.controlsDesktop && !obscured {
                Menu {
                    Toggle("Trackpad Mode", isOn: $trackpad)
                    Toggle("Special Keys", isOn: $specialKeys)
                    if trackpad { Button("Re-center Pointer") { desktop.input("center") } }
                    Button("Hand Back", action: desktop.handBack)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("More")
                .disabled(desktop.actionInProgress)
            }
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if desktop.controlsDesktop {
                if specialKeys { specialKeysRow }
                HStack {
                    chromeButton("Clipboard", symbol: "clipboard") { clipboard = true }
                        .popover(isPresented: $clipboard) {
                            VStack(alignment: .leading, spacing: 12) {
                                PasteButton(payloadType: String.self) { values in
                                    if let text = values.first {
                                        desktop.input("paste", arguments: ["text": String(text.prefix(10_000))])
                                    }
                                    clipboard = false
                                }
                                Button("Copy to Phone") { copyLocally(desktop.clipboard); clipboard = false }
                                    .disabled(desktop.clipboard.isEmpty)
                            }
                            .padding()
                            .presentationCompactAdaptation(.popover)
                        }
                    Spacer()
                    Button(desktop.leaseReason.isEmpty ? "Hand Back" : "I’m done", action: desktop.handBack)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .disabled(desktop.actionInProgress)
                    Spacer()
                    chromeButton("Keyboard", symbol: "keyboard") { keyboard.toggle() }
                }
            } else {
                HStack {
                    Spacer()
                    Button(desktop.someoneElseControls ? "Take Back Control" : "Take Control") {
                        if desktop.someoneElseControls { takeoverConfirmation = true }
                        else { desktop.takeControl(reason: takeoverReason ?? "") }
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(desktop.actionInProgress)
                }
            }
        }
        .controlSize(.large)
    }

    private var specialKeysRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.keys, id: \.code) { key in
                    Button {
                        if key.modifier {
                            if !stickyKeys.insert(key.code).inserted { stickyKeys.remove(key.code) }
                            desktop.input("modifier", arguments: ["key": key.code])
                        } else { sendKey(key.code) }
                    } label: {
                        Text(verbatim: key.caption).frame(minWidth: 30, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(stickyKeys.contains(key.code) ? .blue : .white)
                }
                Button { sendCombo([0xffe3, 0xffe9, 0xffff]) } label: { Text(verbatim: "Ctrl+Alt+Del") }
                    .buttonStyle(.bordered)
                Button { sendCombo([0xffe3, 0xffe1, 0x76]) } label: { Text(verbatim: "Ctrl+Shift+V") }
                    .buttonStyle(.bordered)
            }
        }
        .scrollIndicators(.hidden)
    }

    private static let keys: [(caption: String, code: Int, modifier: Bool)] = [
        ("Esc", 0xff1b, false), ("Tab", 0xff09, false), ("Ctrl", 0xffe3, true),
        ("Alt", 0xffe9, true), ("Super", 0xffeb, true), ("←", 0xff51, false),
        ("↑", 0xff52, false), ("→", 0xff53, false), ("↓", 0xff54, false), ("Del", 0xffff, false)
    ]

    private func sendKey(_ key: Int) {
        desktop.input("key", arguments: ["key": key])
        stickyKeys.removeAll()
    }

    private func sendCombo(_ keys: [Int]) {
        desktop.input("combo", arguments: ["keys": keys])
        stickyKeys.removeAll()
    }

    private func resetInput() {
        keyboard = false
        clipboard = false
        stickyKeys.removeAll()
    }

    private func chromeButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private var helpSheet: some View {
        NavigationStack {
            List {
                Label("Pinch to zoom. Drag to pan while watching.", systemImage: "hand.pinch")
                Label("Take control to click, drag, type, and use the clipboard.", systemImage: "cursorarrow.click")
                Label("Touch and hold for a right click. Use two fingers to scroll.", systemImage: "hand.tap")
                Label("Hand back control to let the Bot use its computer again.", systemImage: "arrow.uturn.backward")
                if live {
                    Button("Turn Off", role: .destructive) {
                        help = false
                        stopConfirmation = true
                    }
                }
            }
            .navigationTitle("Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { help = false } } }
        }
    }

    private var statePanel: some View {
        VStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 84)
            switch desktop.phase {
            case .idle, .loading, .connecting:
                ProgressView("Connecting…").tint(.white)
            case .starting:
                ProgressView("Starting desktop…").tint(.white)
            case .paused:
                Text("Paused")
            case .live:
                EmptyView()
            default:
                Text(statusText).multilineTextAlignment(.center)
                if desktop.phase == .notInstalled, let status = desktop.status {
                    if !status.missing.isEmpty {
                        Text(verbatim: status.missing.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let command = status.installCommand, !command.isEmpty {
                        Text(verbatim: command).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy Command") { copyLocally(command) }.buttonStyle(.bordered)
                    }
                }
                if desktop.phase == .stopped {
                    Button("Start Desktop") { desktop.start() }.buttonStyle(.borderedProminent)
                } else if desktop.phase != .unsupported {
                    Button("Try Again") { desktop.retry() }.buttonStyle(.bordered)
                }
            }
        }
        .foregroundStyle(.white).padding(24).frame(maxWidth: 460)
    }

    private var statusText: String {
        switch desktop.phase {
        case .unsupported: return String(localized: "This Hermes host does not support desktop viewing.")
        case .notInstalled: return String(localized: "Desktop software is not installed on this Hermes host.")
        case .blocked: return desktop.status?.blocker ?? String(localized: "The desktop cannot start. Check its configuration on the Hermes host.")
        case .stopped: return String(localized: "The desktop is off. Starting it runs a desktop on the Hermes host.")
        case .rendererFailed: return String(localized: "Could not load the desktop viewer.")
        default: return desktop.message
        }
    }

    private func copyLocally(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true])
    }
}

@MainActor struct BotDesktopKeyboard: UIViewRepresentable {
    let wantsFocus: Bool
    let type: (String) -> Void
    let key: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(type: type, key: key) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.text = Coordinator.sentinel
        field.textColor = .clear
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) { field.wantsFocus = wantsFocus }
    static func dismantleUIView(_ field: Field, coordinator: Coordinator) { field.wantsFocus = false }

    final class Field: UITextField {
        var wantsFocus = false { didSet { updateFocus() } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateFocus()
        }

        private func updateFocus() {
            if wantsFocus, window != nil, !isFirstResponder {
                becomeFirstResponder()
            } else if !wantsFocus, isFirstResponder {
                resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        static let sentinel = "\u{200B}"
        let type: (String) -> Void
        let key: (Int) -> Void

        init(type: @escaping (String) -> Void, key: @escaping (Int) -> Void) { self.type = type; self.key = key }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            if text.isEmpty { key(0xff08) }
            else {
                let committed = text.hasPrefix(Self.sentinel) ? String(text.dropFirst()) : text
                if !committed.isEmpty { type(committed) }
            }
            field.text = Self.sentinel
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool { key(0xff0d); return false }
    }
}

@MainActor struct BotDesktopChatCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var thumbnail: UIImage?
    @State private var running = false
    @State private var heldByHuman = false
    @State private var supported = true
    let server: URL
    let connection: BotConnection
    let profile: String
    let use: BotDesktopUse
    let held: Bool
    let covered: Bool
    let open: () -> Void
    let takeOver: () -> Void

    private struct Refresh: Equatable {
        let visible: Bool
        let use: BotDesktopUse
    }

    var body: some View {
        let refresh = Refresh(visible: scenePhase == .active && !covered, use: use)
        VStack(alignment: .leading, spacing: 8) {
            if held { Button("You still control the computer", systemImage: "desktopcomputer", action: open) }
            if supported && use != .none {
                Button(action: open) {
                    Color.black.overlay {
                        if refresh.visible, !held, !heldByHuman, let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFit().accessibilityHidden(true)
                        } else {
                            Label(heldByHuman ? "Someone else is using this computer" : "Computer", systemImage: "desktopcomputer")
                                .multilineTextAlignment(.center).foregroundStyle(.white)
                        }
                    }
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Computer")
                if use == .ended && running && !held {
                    Button("Take over the computer", systemImage: "cursorarrow.click", action: takeOver)
                        .buttonStyle(.bordered)
                }
            }
        }
        .task(id: refresh) {
            guard refresh.visible, refresh.use != .none else { return }
            await watch(refresh.use)
        }
    }

    private func watch(_ use: BotDesktopUse) async {
        let client = BotClient(saved: connection, server: server)
        defer { client.close() }
        do {
            try await client.connect()
            let status = try await client.call(.displayStatus(profile: profile))
            try Task.checkCancellation()
            supported = status["supported"].flag == true
            running = status["running"].flag == true
            heldByHuman = status["lease"]["holder"].text == "human"
            if heldByHuman { thumbnail = nil }
            guard supported && running else { return }
            let key = status["profile_key"].text
            var leaseChange = 0
            client.onEvent = { event in
                guard let key, event["type"].text == "display.lease",
                      event["payload"]["profile_key"].text == key else { return }
                leaseChange += 1
                heldByHuman = event["payload"]["lease"]["holder"].text == "human"
                if heldByHuman { thumbnail = nil }
            }
            repeat {
                let revision = leaseChange
                let frame = try await client.call(.displayThumbnail(profile: profile))
                try Task.checkCancellation()
                if revision == leaseChange {
                    heldByHuman = frame["suppressed"].text == "human_has_control"
                    if heldByHuman { thumbnail = nil }
                    else if let value = frame["data_url"].text, value.hasPrefix("data:image/jpeg;base64,"),
                            value.utf8.count <= 1_500_000, let data = Data(base64Encoded: String(value.dropFirst(23))) {
                        thumbnail = UIImage(data: data)
                    }
                }
                guard use == .active else { return }
                try await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled
        } catch {
            guard !Task.isCancelled else { return }
            if error as? BotFailure == .rejected(-32601) { supported = false }
            running = false
        }
    }
}
