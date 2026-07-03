import SwiftUI
import SwiftData

@main
struct HermesMobileApp: App {
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            // Launch argument hook so the Streaming Lab can be opened without
            // UI navigation (agent-driven simulator diagnosis, issue #234):
            // `xcrun simctl launch <udid> com.uzairansar.hermesmobile --streaming-lab`
            if arguments.contains("--streaming-lab") {
                NavigationStack {
                    StreamingLabView()
                }
            } else if arguments.contains("--zora-design-audit") {
                ZoraDesignAuditView(screen: ZoraDesignAuditScreen.fromArguments(arguments))
                    .preferredColorScheme(.dark)
            } else {
                ContentView(authManager: authManager)
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            }
            #else
            ContentView(authManager: authManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            #endif
        }
        .modelContainer(for: [CachedSession.self, CachedMessage.self])
    }
}

#if DEBUG
private enum ZoraDesignAuditScreen: String, CaseIterable, Identifiable {
    case sessions
    case chat
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .chat: "Chat"
        case .settings: "Settings"
        }
    }

    static func fromArguments(_ arguments: [String]) -> ZoraDesignAuditScreen {
        guard let index = arguments.firstIndex(of: "--zora-design-audit-screen"),
              arguments.indices.contains(index + 1),
              let screen = ZoraDesignAuditScreen(rawValue: arguments[index + 1])
        else {
            return .sessions
        }

        return screen
    }
}

private struct ZoraDesignAuditView: View {
    let screen: ZoraDesignAuditScreen

    var body: some View {
        ZStack {
            switch screen {
            case .sessions:
                ZoraAuditSessionsSurface()
            case .chat:
                ZoraAuditChatSurface()
            case .settings:
                ZoraAuditSettingsSurface()
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("DEBUG DESIGN AUDIT · \(screen.title.uppercased())")
                .font(AppFont.caption2(weight: .bold))
                .tracking(0.8)
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ZoraBrand.subtleFill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(ZoraBrand.hairline, lineWidth: 0.75))
                .padding(.top, 14)
                .padding(.trailing, 14)
                .accessibilityHidden(true)
        }
        .zoraBrandedScreen()
    }
}

private struct ZoraAuditSessionsSurface: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZoraHeaderWordmark()

                Spacer(minLength: 0)

                ZoraAuditSearchPill()
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ZoraAuditCard(spacing: 12) {
                        ZoraAuditSidebarRow(icon: "tray.full", title: "Inbox", detail: "12", isSelected: true)
                        ZoraAuditHairline()
                        ZoraAuditSidebarRow(icon: "checklist", title: "Tasks", detail: "4")
                        ZoraAuditSidebarRow(icon: "brain.head.profile", title: "Memory", detail: "Live")
                    }

                    ZoraAuditSectionHeader(title: "Active profile", accessory: "Chief of Staff")
                    ZoraAuditCard(spacing: 12) {
                        ZoraAuditSidebarRow(icon: "sparkles", title: "Zora", detail: "Gemma 3 · 128K", isSelected: true)
                        ZoraAuditSidebarRow(icon: "terminal", title: "Agent Operator", detail: "DGX")
                    }

                    ZoraAuditSectionHeader(title: "Sessions", accessory: "Recent")
                    VStack(spacing: 10) {
                        ZoraAuditSessionRow(
                            title: "Ship Samantha/Zora polish",
                            subtitle: "Design audit · SwiftUI · TestFlight",
                            meta: "Now · 14 messages",
                            isLive: true
                        )
                        ZoraAuditSessionRow(
                            title: "Morning briefing follow-ups",
                            subtitle: "Calendar, inbox, agent handoff",
                            meta: "9:12 AM · 8 messages"
                        )
                        ZoraAuditSessionRow(
                            title: "Code review automation",
                            subtitle: "GitHub PR factory and model routing",
                            meta: "Yesterday · 23 messages"
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 112)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZoraAuditFloatingAction()
                .padding(.trailing, 24)
                .padding(.bottom, 22)
        }
    }
}

private struct ZoraAuditChatSurface: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ZoraAuditChatHeader()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ZoraAuditAssistantTurn(
                            title: "Zora",
                            text: "Recommendation: keep the app emotionally direct, but make the surfaces feel earned — stronger cards, warmer selection, less flat red."
                        )

                        ZoraAuditUserBubble(text: "Continue the design pass and send me the TestFlight build.")

                        ZoraAuditToolCard()

                        ZoraAuditAssistantTurn(
                            title: "Zora",
                            text: "I’ll capture the primary screens, tighten the shared tokens, validate the simulator build, then upload the next SourceBottle train. Slightly glamorous admin, unfortunately."
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 150)
                }
            }

            BottomComposerMaterialFade(composerHeight: 88)
            ZoraAuditComposer()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }
}

private struct ZoraAuditSettingsSurface: View {
    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    ZoraAuditSettingsCard(title: "Identity") {
                        HStack(spacing: 13) {
                            ZoraAuditAvatar(initials: "Z")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Zora")
                                    .font(AppFont.headline(weight: .semibold))
                                    .foregroundStyle(ZoraBrand.foreground)
                                Text("Chief of Staff · SourceBottle")
                                    .font(AppFont.caption())
                                    .foregroundStyle(ZoraBrand.secondaryForeground)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    ZoraAuditSettingsCard(title: "Appearance") {
                        ZoraAuditSettingsRow(icon: "circle.lefthalf.filled", title: "Theme", value: "System")
                        ZoraAuditHairline()
                        ZoraAuditSettingsRow(icon: "paintpalette", title: "Brand color", value: "Warm red")
                        ZoraAuditHairline()
                        ZoraAuditToggleRow(icon: "paintbrush.pointed", title: "Tint New Chat & Send", isOn: true)
                    }

                    ZoraAuditSettingsCard(title: "Chat") {
                        ZoraAuditToggleRow(icon: "brain.head.profile", title: "Thinking and Tool Cards", isOn: true)
                        ZoraAuditHairline()
                        ZoraAuditToggleRow(icon: "sparkles", title: "Streamed Text Animation", isOn: true)
                        ZoraAuditHairline()
                        ZoraAuditSettingsRow(icon: "arrow.up.message", title: "Send While Responding", value: "Steer")
                    }

                    ZoraAuditSettingsCard(title: "Active Server") {
                        ZoraAuditSettingsRow(icon: "server.rack", title: "Status", value: "Connected")
                        ZoraAuditHairline()
                        ZoraAuditSettingsRow(icon: "cpu", title: "Default model", value: "Gemma 3")
                        ZoraAuditHairline()
                        ZoraAuditSettingsRow(icon: "person.crop.circle", title: "Default profile", value: "Zora")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ZoraAuditSearchPill: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
            Text("Search")
        }
        .font(AppFont.subheadline(weight: .semibold))
        .foregroundStyle(ZoraBrand.secondaryForeground)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(ZoraBrand.cardFill, in: Capsule(style: .continuous))
        .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
    }
}

private struct ZoraAuditSectionHeader: View {
    let title: String
    let accessory: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .bold))
                .tracking(0.7)
                .foregroundStyle(ZoraBrand.secondaryForeground)
            Spacer(minLength: 8)
            Text(accessory)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(ZoraBrand.tertiaryForeground)
        }
        .padding(.horizontal, 8)
    }
}

private struct ZoraAuditCard<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoraBrand.cardFillStrong, in: shape)
        .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
        .overlay(shape.stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.22), radius: 18, y: 10)
    }
}

private struct ZoraAuditSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .bold))
                .tracking(0.7)
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .padding(.leading, 4)

            ZoraAuditCard(spacing: 11) {
                content
            }
        }
    }
}

private struct ZoraAuditSidebarRow: View {
    let icon: String
    let title: String
    let detail: String
    var isSelected = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(isSelected ? ZoraBrand.selectionAccent : ZoraBrand.secondaryForeground)
                .frame(width: 25)

            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.foreground)

            Spacer(minLength: 8)

            Text(detail)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(isSelected ? ZoraBrand.selectionAccent : ZoraBrand.tertiaryForeground)
        }
        .frame(minHeight: 38)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ZoraBrand.selectionAccent.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ZoraBrand.selectionAccent.opacity(0.26), lineWidth: 0.75))
            }
        }
    }
}

private struct ZoraAuditSessionRow: View {
    let title: String
    let subtitle: String
    let meta: String
    var isLive = false

    var body: some View {
        ZoraAuditCard(spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                ZoraAuditAvatar(initials: isLive ? "Z" : "C", size: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(ZoraBrand.foreground)
                            .lineLimit(1)

                        if isLive {
                            Circle()
                                .fill(ZoraBrand.selectionAccent)
                                .frame(width: 7, height: 7)
                                .shadow(color: ZoraBrand.selectionAccent.opacity(0.45), radius: 5)
                        }
                    }

                    Text(subtitle)
                        .font(AppFont.caption())
                        .foregroundStyle(ZoraBrand.secondaryForeground)
                        .lineLimit(1)

                    Text(meta)
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(ZoraBrand.tertiaryForeground)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct ZoraAuditChatHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZoraAuditAvatar(initials: "Z", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Design polish")
                    .font(AppFont.headline(weight: .semibold))
                    .foregroundStyle(ZoraBrand.foreground)
                Text("workspace/hermex · Zora")
                    .font(AppFont.caption())
                    .foregroundStyle(ZoraBrand.secondaryForeground)
            }
            Spacer(minLength: 0)
            Image(systemName: "ellipsis")
                .font(AppFont.headline(weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .frame(width: 42, height: 42)
                .background(ZoraBrand.subtleFill, in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [ZoraBrand.backgroundTop, ZoraBrand.backgroundTop.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }
}

private struct ZoraAuditAssistantTurn: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZoraAuditAvatar(initials: "Z", size: 24)
                Text(title)
                    .font(AppFont.caption(weight: .bold))
                    .foregroundStyle(ZoraBrand.secondaryForeground)
            }

            Text(text)
                .font(AppFont.body())
                .lineSpacing(3)
                .foregroundStyle(ZoraBrand.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ZoraAuditUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 52)
            Text(text)
                .font(AppFont.body())
                .foregroundStyle(ZoraBrand.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(ZoraBrand.cardFillStrong, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
        }
    }
}

private struct ZoraAuditToolCard: View {
    var body: some View {
        ZoraAuditCard(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "hammer")
                    .foregroundStyle(ZoraBrand.selectionAccent)
                Text("Tool output")
                    .font(AppFont.caption(weight: .bold))
                    .foregroundStyle(ZoraBrand.secondaryForeground)
                Spacer()
                Text("verified")
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(ZoraBrand.selectionAccent)
            }

            Text("xcodebuild -list returned the HermesMobile scheme and current packages.")
                .font(AppFont.caption())
                .foregroundStyle(ZoraBrand.secondaryForeground)
        }
    }
}

private struct ZoraAuditComposer: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(spacing: 10) {
            Text("Ask Zora to continue…")
                .font(AppFont.body())
                .foregroundStyle(ZoraBrand.tertiaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Image(systemName: "plus")
                Text("Gemma 3")
                Spacer(minLength: 0)
                Image(systemName: "mic")
                Image(systemName: "arrow.up")
                    .foregroundStyle(ZoraBrand.backgroundBottom)
                    .frame(width: 34, height: 34)
                    .background(ZoraBrand.selectionAccent, in: Circle())
            }
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(ZoraBrand.secondaryForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ZoraBrand.cardFillStrong, in: shape)
        .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: shape)
        .overlay(shape.stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.28), radius: 20, y: 12)
    }
}

private struct ZoraAuditSettingsRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .frame(width: 24)
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.foreground)
            Spacer(minLength: 8)
            Text(value)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .lineLimit(1)
        }
        .frame(minHeight: 38)
    }
}

private struct ZoraAuditToggleRow: View {
    let icon: String
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .frame(width: 24)
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(ZoraBrand.foreground)
            Spacer(minLength: 8)
            Capsule(style: .continuous)
                .fill(isOn ? ZoraBrand.selectionAccent : ZoraBrand.subtleFill)
                .frame(width: 44, height: 26)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? ZoraBrand.backgroundBottom : ZoraBrand.secondaryForeground)
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
        }
        .frame(minHeight: 38)
    }
}

private struct ZoraAuditFloatingAction: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
            Text("New Chat")
                .font(AppFont.subheadline(weight: .bold))
        }
        .foregroundStyle(ZoraBrand.backgroundBottom)
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(ZoraBrand.selectionAccent, in: Capsule(style: .continuous))
        .shadow(color: Color.black.opacity(0.32), radius: 18, y: 10)
    }
}

private struct ZoraAuditAvatar: View {
    let initials: String
    var size: CGFloat = 38

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(ZoraBrand.backgroundBottom)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [ZoraBrand.foreground, ZoraBrand.selectionAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay(Circle().stroke(ZoraBrand.cardStroke, lineWidth: 0.75))
    }
}

private struct ZoraAuditHairline: View {
    var body: some View {
        Rectangle()
            .fill(ZoraBrand.hairline)
            .frame(height: 0.75)
            .padding(.leading, 2)
    }
}
#endif
