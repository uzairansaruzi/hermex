import SwiftUI

enum OnboardingConnectField: Hashable {
    case serverURL
    case username
    case password
}

struct OnboardingConnectPage: View {
    @Bindable var viewModel: OnboardingViewModel
    @Bindable var authManager: AuthManager
    @FocusState.Binding var focusedField: OnboardingConnectField?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingAdvanced = false

    private let accent = Color(red: 1.0, green: 0.74, blue: 0.10)
    private let success = Color(red: 0.45, green: 0.92, blue: 0.56)

    private func submitConnection() {
        guard viewModel.canSubmit, !viewModel.isConnectionLocked else { return }
        Task { await viewModel.connect(authManager: authManager) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    ConnectionModePicker(selection: $viewModel.connectionMode, style: .onboarding)
                        .padding(.horizontal, 13)
                        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .disabled(viewModel.isConnectionLocked)

                    Text(viewModel.connectionMode.help)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    OnboardingField(systemImage: "link", title: String(localized: "Server URL")) {
                        ZStack(alignment: .leading) {
                            if viewModel.serverURLString.isEmpty {
                                Text(verbatim: viewModel.connectionMode.placeholder)
                                    .foregroundStyle(.white.opacity(0.38))
                                    .lineLimit(1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }

                            TextField("", text: $viewModel.serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(.white)
                                .submitLabel(.go)
                                .tint(accent)
                                .focused($focusedField, equals: .serverURL)
                                .disabled(viewModel.isConnectionLocked)
                                .onSubmit(submitConnection)
                                .accessibilityLabel(Text("Server URL"))
                        }
                    }

                    // The trailing mark keeps a URL ending in a neutral character, such as an
                    // IPv6 literal's "]", in one left-to-right run inside right-to-left text.
                    if let preview = viewModel.addressPreview {
                        Text("Will connect to \(preview.absoluteString + "\u{200E}")")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    statusMessages

                    if viewModel.showsHermesSignIn {
                        savedSignInRows

                        OnboardingField(systemImage: "person.fill", title: String(localized: "Username")) {
                            TextField(
                                "",
                                text: $viewModel.username,
                                prompt: Text("Dashboard username")
                                    .foregroundStyle(.white.opacity(0.38))
                            )
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .disabled(viewModel.isConnectionLocked)
                            .onSubmit { focusedField = .password }
                        }
                    }

                    if viewModel.showsPasswordField {
                        OnboardingField(systemImage: "key.fill", title: String(localized: "Password")) {
                            SecureField(
                                "",
                                text: $viewModel.password,
                                prompt: (viewModel.detectedKind == .hermes ? Text("Dashboard password") : Text("Server password"))
                                    .foregroundStyle(.white.opacity(0.38))
                            )
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .disabled(viewModel.isConnectionLocked)
                            .onSubmit(submitConnection)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.connectionMode == .cloudflareTunnel {
                            Text("Cloudflare Access: paste your service token’s Client ID and Client Secret as the values. Leave both empty if Access is off.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        CustomHeadersEditor(headers: $viewModel.customHeaders, style: .onboarding)
                    }
                    .disabled(viewModel.isConnectionLocked)
                    .padding(.top, 10)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .tint(.white.opacity(0.6))
            }
            .padding(.horizontal, 22)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 18 : 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: viewModel.connectionMode) { _, mode in
            // The Access rows Cloudflare Tunnel adds sit in Advanced, so they open with it.
            if mode == .cloudflareTunnel { isShowingAdvanced = true }
        }
    }

    /// What the last Connect or Test Connection found, next to the address it is about.
    @ViewBuilder
    private var statusMessages: some View {
        if viewModel.isWorking {
            OnboardingStatusBanner(
                text: String(localized: "Checking server..."),
                systemImage: "arrow.triangle.2.circlepath",
                tint: .white.opacity(0.7),
                showsProgress: true
            )
        } else if viewModel.showsHermesSignIn {
            OnboardingStatusBanner(
                text: String(localized: "Hermes dashboard found. Sign in with your dashboard username and password."),
                systemImage: "checkmark.circle.fill",
                tint: success
            )
        }

        if viewModel.needsBotModeOptIn {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes dashboard found")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Adding one needs Bot Mode (beta), which is off. Bot Mode is unfinished, and you can turn it off again in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Button {
                    viewModel.enableBotMode()
                    focusedField = .username
                } label: {
                    Text("Turn on Bot Mode (beta) and continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .disabled(viewModel.isConnectionLocked)
            }
            .padding(12)
            .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(accent.opacity(0.2), lineWidth: 1)
            )
        }

        if let connectionMessage = viewModel.connectionMessage {
            OnboardingStatusBanner(text: connectionMessage, systemImage: "checkmark.circle.fill", tint: success)
        }

        if let errorMessage = viewModel.errorMessage {
            OnboardingStatusBanner(
                text: errorMessage,
                systemImage: "exclamationmark.triangle.fill",
                tint: Color(red: 1.0, green: 0.47, blue: 0.34)
            )
        }
    }

    /// One row per webui server whose Hermes connection uses exactly this address, or the
    /// note that the fields came from one.
    @ViewBuilder
    private var savedSignInRows: some View {
        if let reused = viewModel.reusedSignIn {
            Label("Filled in from \(reused.serverName)’s Hermes connection.", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            ForEach(viewModel.savedSignIns, id: \.connection.id) { saved in
                Button {
                    viewModel.useSavedSignIn(saved)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use the sign-in saved on \(saved.serverName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(accent)
                            Text("Fills in the username, password and headers.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(accent.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isConnectionLocked)
                .accessibilityLabel(Text("Use the sign-in saved on \(saved.serverName)"))
                .accessibilityHint(Text("Fills in the username, password and headers."))
            }
        }
    }
}
