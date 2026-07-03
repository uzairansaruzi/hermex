import SwiftUI

struct OnboardingView: View {
    @Bindable var authManager: AuthManager
    @State private var viewModel: OnboardingViewModel
    @State private var currentPage: Int
    @State private var hasCopiedAgentPrompt = false
    @State private var hasBypassedCopyReminder = false
    @State private var isShowingCopyReminder = false
    @FocusState private var focusedField: OnboardingConnectField?

    init(authManager: AuthManager, savedServer: URL? = nil) {
        self.authManager = authManager
        // A known server means a re-login, not first-run setup: skip the
        // intro pager and land on the connect page with the server filled in.
        _viewModel = State(
            initialValue: OnboardingViewModel(
                savedServer: savedServer,
                // Headers survive a session-expiry sign-out, so prefill them on
                // re-login behind a proxy (empty on first run / full sign-out).
                savedHeaders: authManager.currentCustomHeaders,
                initialErrorMessage: savedServer == nil ? nil : authManager.lastErrorMessage
            )
        )
        _currentPage = State(
            initialValue: savedServer == nil ? 0 : OnboardingFlowPolicy.connectPageIndex
        )
    }

    private var isEditingConnectionField: Bool {
        currentPage == OnboardingFlowPolicy.connectPageIndex && focusedField != nil
    }

    private var canSubmitConnection: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            ZoraBrandBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

                    OnboardingFeaturesPage()
                        .tag(1)

                    OnboardingAgentPromptPage(hasCopiedAgentPrompt: $hasCopiedAgentPrompt)
                        .tag(2)

                    OnboardingTailscalePage()
                        .tag(3)

                    OnboardingConnectPage(
                        viewModel: viewModel,
                        authManager: authManager,
                        focusedField: $focusedField
                    )
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditingConnectionField {
                keyboardActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditingConnectionField)
        .preferredColorScheme(.dark)
        .onChange(of: currentPage) { oldPage, newPage in
            handlePageChange(from: oldPage, to: newPage)
        }
        .alert("Copy the setup prompt first", isPresented: $isShowingCopyReminder) {
            Button("Stay Here", role: .cancel) {}
            Button("Continue Anyway") {
                hasBypassedCopyReminder = true
                advanceToNextPage()
            }
        } message: {
            Text("Copy the agent setup prompt on your desktop before continuing so Hermes Web UI and Tailscale are configured correctly.")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            OnboardingPageIndicator(
                pageCount: OnboardingFlowPolicy.pageCount,
                currentPage: currentPage
            )

            if currentPage == OnboardingFlowPolicy.connectPageIndex {
                if !isEditingConnectionField {
                    connectActionButtons
                }
            } else {
                Button(action: handlePrimaryAction) {
                    Text(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))
                }
                .buttonStyle(ZoraPrimaryButtonStyle(cornerRadius: ZoraRadius.small))
                .accessibilityLabel(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))

                if OnboardingFlowPolicy.showsServerShortcut(for: currentPage) {
                    Button("Already have a server?") {
                        jumpToConnectPage()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ZoraBrand.secondaryForeground)
                    .buttonStyle(.plain)
                    .accessibilityHint("Skips setup and opens the connect screen.")
                }
            }
        }
        .padding(.horizontal, ZoraSpacing.screenInset)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, ZoraBrand.darkBackground.opacity(0.72), ZoraBrand.darkBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
            .offset(y: -50),
            alignment: .top
        )
    }

    private var keyboardActionBar: some View {
        VStack(spacing: 10) {
            connectActionButtons
        }
        .padding(.horizontal, ZoraSpacing.screenInset - 2)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var connectActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                testConnectionButton
                connectButton
            }

            VStack(spacing: 10) {
                testConnectionButton
                connectButton
            }
        }
    }

    private var testConnectionButton: some View {
        Button {
            Task { await viewModel.testConnection(authManager: authManager) }
        } label: {
            Label("Test Connection", systemImage: "network")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ZoraSecondaryButtonStyle(cornerRadius: ZoraRadius.small))
        .disabled(viewModel.isWorking || !canSubmitConnection)
    }

    private var connectButton: some View {
        Button {
            Task { await viewModel.connect(authManager: authManager) }
        } label: {
            Label("Connect", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ZoraPrimaryButtonStyle(cornerRadius: ZoraRadius.small))
        .disabled(viewModel.isWorking || !canSubmitConnection)
    }

    private func handlePrimaryAction() {
        if OnboardingFlowPolicy.shouldShowCopyReminder(
            page: currentPage,
            hasCopiedAgentPrompt: hasCopiedAgentPrompt,
            hasBypassedCopyReminder: hasBypassedCopyReminder
        ) {
            isShowingCopyReminder = true
            return
        }

        if currentPage < OnboardingFlowPolicy.connectPageIndex {
            advanceToNextPage()
        }
    }

    private func handlePageChange(from oldPage: Int, to newPage: Int) {
        if OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(newPage) {
            focusedField = nil
        }

        guard OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
            from: oldPage,
            to: newPage,
            hasCopiedAgentPrompt: hasCopiedAgentPrompt,
            hasBypassedCopyReminder: hasBypassedCopyReminder
        ) else {
            return
        }

        isShowingCopyReminder = true
        currentPage = oldPage
    }

    private func advanceToNextPage() {
        guard currentPage < OnboardingFlowPolicy.connectPageIndex else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }

    private func jumpToConnectPage() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage = OnboardingFlowPolicy.connectPageIndex
        }
    }
}

#Preview {
    OnboardingView(authManager: AuthManager())
}
