import AuthenticationServices
import SwiftUI

struct OnboardingView: View {
    /// Height of the fade the bottom bar paints over the pager. Pages that end in a control
    /// pad their scroll content past it so the control can scroll clear of the fade.
    #if targetEnvironment(macCatalyst)
    static let bottomFadeHeight: CGFloat = 0
    #else
    static let bottomFadeHeight: CGFloat = 50
    #endif

    @Bindable var authManager: AuthManager
    @State private var viewModel: OnboardingViewModel
    @State private var currentPage: Int
    @State private var shownSetupPrompt = OnboardingFlowPolicy.initialSetupPrompt
    @State private var copiedSetupPrompts: Set<OnboardingSetupPrompt> = []
    /// The prompts whose copy reminder Continue Anyway skipped.
    @State private var bypassedSetupPrompts: Set<OnboardingSetupPrompt> = []
    @State private var isShowingCopyReminder = false
    private let isReturningSignIn: Bool
    @FocusState private var focusedField: OnboardingConnectField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(authManager: AuthManager, savedServer: URL? = nil) {
        self.authManager = authManager
        isReturningSignIn = savedServer != nil
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
        #if targetEnvironment(macCatalyst)
        // A hardware keyboard doesn't need the phone's keyboard accessory bar.
        false
        #else
        currentPage == OnboardingFlowPolicy.connectPageIndex && focusedField != nil
        #endif
    }

    private var hasServerURL: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if targetEnvironment(macCatalyst)
            NavigationStack {
                desktopContent
                    .background(Color.black)
                    .navigationTitle(Text(verbatim: "Hermex"))
                    .toolbar(.hidden, for: .navigationBar)
            }
            #else
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingWelcomePage()
                        .tag(0)

                    OnboardingFeaturesPage()
                        .tag(1)

                    OnboardingAgentPromptPage(
                        shownPrompt: $shownSetupPrompt,
                        copiedPrompts: $copiedSetupPrompts
                    )
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
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditingConnectionField {
                keyboardActionBar
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isEditingConnectionField)
        .preferredColorScheme(.dark)
        .onChange(of: currentPage) { oldPage, newPage in
            handlePageChange(from: oldPage, to: newPage)
        }
        .alert("Copy the setup prompt first", isPresented: $isShowingCopyReminder) {
            Button("Stay Here", role: .cancel) {}
            Button("Continue Anyway") {
                bypassedSetupPrompts.insert(shownSetupPrompt)
                advanceToNextPage()
            }
        } message: {
            Text(shownSetupPrompt.copyReminderMessage)
        }
    }

    #if targetEnvironment(macCatalyst)
    private var desktopContent: some View {
        VStack(spacing: 0) {
            HStack {
                if currentPage > 0 && !isReturningSignIn {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { currentPage -= 1 }
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .keyboardShortcut("[", modifiers: .command)
                }
                Spacer()
            }
            .frame(minHeight: 28)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 8)

            desktopPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(currentPage)

            bottomBar.fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 640, maxHeight: currentPage == OnboardingFlowPolicy.connectPageIndex ? 600 : 720)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var desktopPage: some View {
        switch currentPage {
        case 0: OnboardingWelcomePage()
        case 1: OnboardingFeaturesPage()
        case 2: OnboardingAgentPromptPage(shownPrompt: $shownSetupPrompt, copiedPrompts: $copiedSetupPrompts)
        case 3: OnboardingTailscalePage()
        default: OnboardingConnectPage(viewModel: viewModel, authManager: authManager, focusedField: $focusedField)
        }
    }
    #endif

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if !isReturningSignIn || !isDesktop {
                OnboardingPageIndicator(pageCount: OnboardingFlowPolicy.pageCount, currentPage: currentPage)
            }

            if currentPage == OnboardingFlowPolicy.connectPageIndex {
                if !isEditingConnectionField {
                    connectActionButtons
                }
            } else {
                Button(action: handlePrimaryAction) {
                    Text(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Color(red: 1.0, green: 0.74, blue: 0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                #if targetEnvironment(macCatalyst)
                .keyboardShortcut(.defaultAction)
                #endif
                .accessibilityLabel(OnboardingFlowPolicy.primaryButtonTitle(for: currentPage))

                if OnboardingFlowPolicy.showsServerShortcut(for: currentPage) {
                    Button("Already have a server?") {
                        jumpToConnectPage()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                    .accessibilityHint("Skips setup and opens the connect screen.")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        #if !targetEnvironment(macCatalyst)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.bottomFadeHeight)
            .offset(y: -Self.bottomFadeHeight)
            // The fade overlaps the page above it; let taps reach the page's controls.
            .allowsHitTesting(false),
            alignment: .top
        )
        #endif
    }

    private var isDesktop: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    private var keyboardActionBar: some View {
        VStack(spacing: 10) {
            connectActionButtons
        }
        .padding(.horizontal, 22)
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
        .buttonStyle(OnboardingSecondaryButtonStyle())
        .disabled(viewModel.isWorking || !hasServerURL)
    }

    private var connectButton: some View {
        Button {
            Task { await viewModel.connect(authManager: authManager, browser: .init(webAuthenticationSession)) }
        } label: {
            Group {
                if viewModel.signInMethod == .browser {
                    Label("Sign In with Browser", systemImage: "safari")
                } else {
                    Label("Connect", systemImage: "checkmark.circle.fill")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        #if targetEnvironment(macCatalyst)
        .keyboardShortcut(.return, modifiers: .command)
        #endif
        .disabled(viewModel.isWorking || !viewModel.canSubmit)
    }

    private func handlePrimaryAction() {
        if OnboardingFlowPolicy.shouldShowCopyReminder(
            page: currentPage,
            shownPrompt: shownSetupPrompt,
            copiedPrompts: copiedSetupPrompts,
            bypassedPrompts: bypassedSetupPrompts
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
            shownPrompt: shownSetupPrompt,
            copiedPrompts: copiedSetupPrompts,
            bypassedPrompts: bypassedSetupPrompts
        ) else {
            return
        }

        isShowingCopyReminder = true
        currentPage = oldPage
    }

    private func advanceToNextPage() {
        guard currentPage < OnboardingFlowPolicy.connectPageIndex else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }

    private func jumpToConnectPage() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            currentPage = OnboardingFlowPolicy.connectPageIndex
        }
    }
}

#Preview {
    OnboardingView(authManager: AuthManager())
}
