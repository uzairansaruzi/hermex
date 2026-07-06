import SwiftUI
import HermexCore

public struct HermexOnboardingScreen: View {
    private let appState: HermexAppState
    private let onboarding: HermexOnboardingState
    private let settings: HermexSettingsState
    private let onEvent: (HermexUIEvent) -> Void

    public init(
        appState: HermexAppState,
        onboarding: HermexOnboardingState = HermexOnboardingState(),
        settings: HermexSettingsState = HermexSettingsState(),
        onEvent: @escaping (HermexUIEvent) -> Void = { _ in }
    ) {
        self.appState = appState
        self.onboarding = onboarding
        self.settings = settings
        self.onEvent = onEvent
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    HermexLogoMark()
                        .frame(width: HermexLayoutContract.sessionListLogoWidth)
                    Spacer()
                    if appState.auth != .unconfigured {
                        HermexCircleIconButton(systemImage: "xmark", accessibilityLabel: "Sessions") {
                            onEvent(.openRoute(.sessions))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect to Hermex")
                        .font(.largeTitle.bold())
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                serverPicker
                connectionForm
                statusBlock

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 34)
        }
    }

    private var serverPicker: some View {
        Group {
            if !settings.servers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved servers")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(settings.servers, id: \.baseURL) { server in
                                Button {
                                    onEvent(.selectServer(server))
                                } label: {
                                    Text(server.displayName)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private var connectionForm: some View {
        HermexGlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                fieldLabel("Server URL", systemImage: "link")
                TextField(
                    "https://hermes.example.com",
                    text: Binding(
                        get: { onboarding.serverURLString },
                        set: { onEvent(.updateOnboardingServerURL($0)) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                fieldLabel("Name", systemImage: "server.rack")
                TextField(
                    "Hermex",
                    text: Binding(
                        get: { onboarding.displayName },
                        set: { onEvent(.updateOnboardingDisplayName($0)) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                fieldLabel("Password", systemImage: "lock")
                SecureField(
                    "Server password",
                    text: Binding(
                        get: { onboarding.password },
                        set: { onEvent(.updateOnboardingPassword($0)) }
                    )
                )
                .textFieldStyle(.roundedBorder)

                fieldLabel("Custom headers", systemImage: "slider.horizontal.3")
                TextEditor(
                    text: Binding(
                        get: { onboarding.customHeaderText },
                        set: { onEvent(.updateOnboardingCustomHeaders($0)) }
                    )
                )
                .font(.footnote.monospaced())
                .frame(minHeight: 74)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(HermexUIColors.separator, lineWidth: 0.6)
                )

                HStack(spacing: 10) {
                    Button {
                        onEvent(.testOnboardingConnection)
                    } label: {
                        if onboarding.isTestingConnection {
                            ProgressView()
                        } else {
                            Label("Test", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(onboarding.isTestingConnection || onboarding.isSigningIn)

                    Button {
                        onEvent(.connectOnboarding)
                    } label: {
                        if onboarding.isSigningIn {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Connect")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onboarding.isTestingConnection || onboarding.isSigningIn)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        if let error = onboarding.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        } else if let status = onboarding.statusMessage {
            Label(status, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func fieldLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch appState.auth {
        case .unconfigured:
            return "Add your server to start chatting."
        case .loggedOut(let server):
            return "Sign in to \(server.displayName)."
        case .loggedIn(let server):
            return "Connected to \(server.displayName)."
        }
    }
}
