import SwiftUI

enum OnboardingConnectField: Hashable {
    case serverURL
    case password
}

struct OnboardingConnectPage: View {
    @Bindable var viewModel: OnboardingViewModel
    @Bindable var authManager: AuthManager
    @FocusState.Binding var focusedField: OnboardingConnectField?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingAdvanced = false

    private var canSubmit: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitConnection() {
        guard canSubmit else { return }
        Task { await viewModel.connect(authManager: authManager) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ZoraBrand.foreground)

                    Text("Enter the Tailscale URL your agent returned, for example `http://<tailnet-ip>:8787`.")
                        .font(.footnote)
                        .foregroundStyle(ZoraBrand.tertiaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    OnboardingField(systemImage: "link", title: String(localized: "Server URL")) {
                        ZStack(alignment: .leading) {
                            if viewModel.serverURLString.isEmpty {
                                Text(verbatim: "http://100.64.0.1:8787")
                                    .foregroundStyle(ZoraBrand.tertiaryForeground)
                                    .allowsHitTesting(false)
                            }

                            TextField("", text: $viewModel.serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(ZoraBrand.foreground)
                                .submitLabel(.go)
                                .tint(ZoraBrand.foreground)
                                .focused($focusedField, equals: .serverURL)
                                .onSubmit(submitConnection)
                        }
                    }

                    if viewModel.isPasswordRequired {
                        OnboardingField(systemImage: "key.fill", title: String(localized: "Password")) {
                            SecureField(
                                "",
                                text: $viewModel.password,
                                prompt: Text("Server password")
                                    .foregroundStyle(ZoraBrand.tertiaryForeground)
                            )
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit(submitConnection)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    CustomHeadersEditor(headers: $viewModel.customHeaders, style: .onboarding)
                        .padding(.top, 10)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ZoraBrand.secondaryForeground)
                }
                .tint(ZoraBrand.secondaryForeground)

                if viewModel.isWorking {
                    OnboardingStatusBanner(
                        text: String(localized: "Checking server..."),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: ZoraBrand.secondaryForeground,
                        showsProgress: true
                    )
                }

                if let connectionMessage = viewModel.connectionMessage {
                    OnboardingStatusBanner(
                        text: connectionMessage,
                        systemImage: "checkmark.circle.fill",
                        tint: ZoraBrand.success
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    OnboardingStatusBanner(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: ZoraBrand.danger
                    )
                }
            }
            .padding(.horizontal, ZoraSpacing.screenInset - 2)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 18 : 24)
            .padding(.bottom, ZoraSpacing.section)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
