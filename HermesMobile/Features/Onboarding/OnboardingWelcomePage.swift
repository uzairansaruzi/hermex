import SwiftUI

struct OnboardingWelcomePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var iconSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 108 : 124
    }

    private var iconCornerRadius: CGFloat {
        iconSize * 0.22
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                ZStack {
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.74, blue: 0.10).opacity(0.55),
                            Color(red: 1.0, green: 0.62, blue: 0.08).opacity(0.22),
                            .clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: iconSize * 1.45
                    )
                    .frame(width: iconSize * 2.6, height: iconSize * 2.6)
                    .blur(radius: 18)

                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.78, blue: 0.18).opacity(0.35),
                            .clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: iconSize * 0.95
                    )
                    .frame(width: iconSize * 1.8, height: iconSize * 1.8)

                    Image("HermesAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.25), .white.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: Color(red: 1.0, green: 0.62, blue: 0.08).opacity(0.35), radius: 24, y: 10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hermex")

                Spacer(minLength: 32)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Control your Hermes agent from iPhone or iPad.")
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 27 : 31, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.86)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Connect to your self-hosted Web UI over Tailscale.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        HeroBadge(systemImage: "lock.shield.fill", title: String(localized: "Password protected"))
                        HeroBadge(systemImage: "network", title: String(localized: "Tailscale ready"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
    }
}
