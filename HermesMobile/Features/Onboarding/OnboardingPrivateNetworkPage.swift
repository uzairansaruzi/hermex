import SwiftUI

struct OnboardingPrivateNetworkPage: View {
    @Environment(\.openURL) private var openURL
    @Binding var privateNetworkProvider: PrivateNetworkProvider

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 2,
                    icon: "iphone.and.arrow.forward",
                    title: String(localized: "Connect your iPhone"),
                    description: String(localized: "Install your chosen private-network app on your iPhone. Your agent will reply with the exact URL to use on the next screen.")
                )

                OnboardingNetworkProviderPicker(selection: $privateNetworkProvider)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(privateNetworkProvider.iphoneSetupSteps.enumerated()), id: \.offset) { index, step in
                        networkStep(number: String(index + 1), text: step)
                    }

                    Button(action: openProviderInAppStore) {
                        Label("Get \(privateNetworkProvider.rawValue) on the App Store", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the selected private-network app in the App Store.")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func openProviderInAppStore() {
        openURL(privateNetworkProvider.appStoreURL, completion: { accepted in
            guard !accepted else { return }
            openURL(privateNetworkProvider.appStoreFallbackURL)
        })
    }

    private func networkStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 23, height: 23)
                .background(Color(red: 1.0, green: 0.74, blue: 0.10), in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
