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
                    description: String(localized: "Send this prompt to your Hermes Agent. It installs Hermes Web UI, enables password auth, and configures Tailscale access.")
                )

                OnboardingAgentPromptCard(
                    prompt: OnboardingFlowPolicy.agentSetupPrompt,
                    hasCopied: $hasCopiedAgentPrompt
                )
            }
            .padding(.horizontal, ZoraSpacing.screenInset + (ZoraSpacing.unit / 2))
            .padding(.top, ZoraSpacing.section)
            .padding(.bottom, ZoraSpacing.card)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
