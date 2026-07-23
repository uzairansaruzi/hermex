import SwiftUI

struct OnboardingAgentPromptPage: View {
    @Binding var hasCopiedAgentPrompt: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 1,
                    icon: "terminal",
                    title: String(localized: "Set up Hermes Web UI"),
                    description: String(localized: "Send this prompt to your Hermes Agent. It audits existing state, keeps Hermes Web UI on localhost, and configures private HTTPS with Tailscale Serve.")
                )

                OnboardingAgentPromptCard(
                    prompt: OnboardingFlowPolicy.agentSetupPrompt,
                    hasCopied: $hasCopiedAgentPrompt
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
