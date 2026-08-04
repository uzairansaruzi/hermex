import SwiftUI

struct OnboardingAgentPromptPage: View {
    @Binding var hasCopiedAgentPrompt: Bool
    @Binding var privateNetworkProvider: PrivateNetworkProvider

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 1,
                    icon: "terminal",
                    title: String(localized: "Set up Hermes Web UI"),
                    description: String(localized: "Choose your private network, then send the setup prompt to your Hermes Agent.")
                )

                OnboardingNetworkProviderPicker(selection: $privateNetworkProvider)

                OnboardingAgentPromptCard(
                    prompt: privateNetworkProvider.setupPrompt,
                    hasCopied: $hasCopiedAgentPrompt
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: privateNetworkProvider) {
            hasCopiedAgentPrompt = false
        }
    }
}
