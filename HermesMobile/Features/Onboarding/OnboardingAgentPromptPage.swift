import SwiftUI

struct OnboardingAgentPromptPage: View {
    @Binding var shownPrompt: OnboardingSetupPrompt
    @Binding var copiedPrompts: Set<OnboardingSetupPrompt>

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 1,
                    icon: "terminal",
                    title: shownPrompt.title,
                    description: shownPrompt.description
                )

                VStack(spacing: 16) {
                    OnboardingAgentPromptCard(
                        prompt: shownPrompt.text,
                        isCopied: copiedPrompts.contains(shownPrompt),
                        onCopy: { copiedPrompts.insert(shownPrompt) }
                    )

                    Button(shownPrompt.switchTitle) {
                        shownPrompt = shownPrompt.alternative
                    }
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, OnboardingView.bottomFadeHeight + 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
