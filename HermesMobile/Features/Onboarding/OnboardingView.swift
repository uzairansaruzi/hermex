import SwiftUI

/// First launch, and a webui server signing in again (#1540): one welcome page whose "Add your
/// server" opens the Add Server sheet (`AddServerView`, entry `.onboarding`), with the setup
/// prompt and private-network pages behind "I don't have one yet". Given a saved server, the
/// sheet opens at once with its address filled in.
struct OnboardingView: View {
    /// Height of the fade the bottom bar paints over the pager. Pages that end in a control
    /// pad their scroll content past it so the control can scroll clear of the fade.
    static let bottomFadeHeight: CGFloat = 50

    @Bindable var authManager: AuthManager
    private let savedServer: URL?
    @State private var isAddingServer: Bool
    @State private var isShowingSetup = false
    @State private var currentPage = 0
    @State private var shownSetupPrompt = OnboardingFlowPolicy.initialSetupPrompt
    @State private var copiedSetupPrompts: Set<OnboardingSetupPrompt> = []
    /// The prompts whose copy reminder Continue Anyway skipped.
    @State private var bypassedSetupPrompts: Set<OnboardingSetupPrompt> = []
    @State private var isShowingCopyReminder = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(authManager: AuthManager, savedServer: URL? = nil) {
        self.authManager = authManager
        self.savedServer = savedServer
        // A known server means a sign-in again, not first-run setup.
        _isAddingServer = State(initialValue: savedServer != nil)
    }

    var body: some View {
        NavigationStack {
            OnboardingWelcomePage(addServer: { isAddingServer = true }, setUp: { isShowingSetup = true })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $isShowingSetup) { setupPages }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isAddingServer) {
            AddServerView(authManager: authManager, entry: .onboarding, savedServer: savedServer)
        }
    }

    /// "I don't have one yet": the setup prompt, then joining a private network, then the sheet.
    private var setupPages: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    OnboardingAgentPromptPage(
                        shownPrompt: $shownSetupPrompt,
                        copiedPrompts: $copiedSetupPrompts
                    )
                    .tag(OnboardingFlowPolicy.agentPromptPageIndex)

                    OnboardingTailscalePage()
                        .tag(OnboardingFlowPolicy.agentPromptPageIndex + 1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .onChange(of: currentPage) { oldPage, newPage in
            handlePageChange(from: oldPage, to: newPage)
        }
        .alert("Copy the setup prompt first", isPresented: $isShowingCopyReminder) {
            Button("Stay Here", role: .cancel) {}
            Button("Continue Anyway") {
                bypassedSetupPrompts.insert(shownSetupPrompt)
                advance()
            }
        } message: {
            Text(shownSetupPrompt.copyReminderMessage)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            OnboardingPageIndicator(
                pageCount: OnboardingFlowPolicy.setupPageCount,
                currentPage: currentPage
            )

            Button(action: handlePrimaryAction) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())

            Button("Already have a server?") {
                isAddingServer = true
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
            .buttonStyle(.plain)
            .accessibilityHint("Skips setup and opens the connect screen.")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
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
        advance()
    }

    private func handlePageChange(from oldPage: Int, to newPage: Int) {
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

    /// The next setup page, or the Add Server sheet after the last.
    private func advance() {
        guard let next = OnboardingFlowPolicy.page(after: currentPage) else {
            isAddingServer = true
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            currentPage = next
        }
    }
}

#Preview {
    OnboardingView(authManager: AuthManager())
}
