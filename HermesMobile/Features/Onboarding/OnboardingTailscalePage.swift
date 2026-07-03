import SwiftUI

struct OnboardingTailscalePage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 2,
                    icon: "iphone.and.arrow.forward",
                    title: String(localized: "Install Tailscale on iPhone"),
                    description: String(localized: "Install Tailscale on your iPhone and sign into the same tailnet as your server. Your agent will reply with the exact URL to use on the next screen.")
                )

                VStack(alignment: .leading, spacing: 14) {
                    tailscaleStep(number: "1", text: String(localized: "Install Tailscale from the App Store."))
                    tailscaleStep(number: "2", text: String(localized: "Sign in with the same account you used on your server."))
                    tailscaleStep(number: "3", text: String(localized: "Keep Tailscale connected while using Hermex."))

                    Button(action: openTailscaleInAppStore) {
                        Label("Get Tailscale on the App Store", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ZoraBrand.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(ZoraSecondaryButtonStyle(cornerRadius: ZoraRadius.small))
                    .accessibilityHint("Opens the Tailscale page in the App Store.")
                }
            }
            .padding(.horizontal, ZoraSpacing.screenInset + (ZoraSpacing.unit / 2))
            .padding(.top, ZoraSpacing.section)
            .padding(.bottom, ZoraSpacing.card)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func openTailscaleInAppStore() {
        openURL(OnboardingFlowPolicy.tailscaleAppStoreURL, completion: { accepted in
            guard !accepted else { return }
            openURL(OnboardingFlowPolicy.tailscaleAppStoreFallbackURL)
        })
    }

    private func tailscaleStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(ZoraBrand.ink)
                .frame(width: 23, height: 23)
                .background(ZoraBrand.foreground, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(ZoraBrand.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
