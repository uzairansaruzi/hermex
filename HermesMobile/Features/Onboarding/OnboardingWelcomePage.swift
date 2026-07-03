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
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                ZStack {
                    RadialGradient(
                        colors: [
                            ZoraBrand.foreground.opacity(0.48),
                            ZoraBrand.foreground.opacity(0.18),
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
                            ZoraBrand.foreground.opacity(0.28),
                            .clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: iconSize * 0.95
                    )
                    .frame(width: iconSize * 1.8, height: iconSize * 1.8)

                    ZoraHeaderWordmark()
                        .frame(width: iconSize * 1.45, height: iconSize * 0.42)
                        .padding(.horizontal, ZoraSpacing.lg - (ZoraSpacing.unit / 4))
                        .padding(.vertical, 26)
                        .background(ZoraBrand.subtleFill, in: RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [ZoraBrand.foreground.opacity(0.34), ZoraBrand.foreground.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: ZoraBrand.foreground.opacity(0.18), radius: 24, y: 10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ZoraBrand.accessibilityLabel)

                Spacer(minLength: 32)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Control your Zora agent from iPhone.")
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 27 : 31, weight: .bold))
                        .foregroundStyle(ZoraBrand.foreground)
                        .lineLimit(3)
                        .minimumScaleFactor(0.86)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Connect to your self-hosted Hermes Web UI over Tailscale.")
                        .font(.subheadline)
                        .foregroundStyle(ZoraBrand.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        HeroBadge(systemImage: "lock.shield.fill", title: String(localized: "Password protected"))
                        HeroBadge(systemImage: "network", title: String(localized: "Tailscale ready"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZoraSpacing.screenInset + (ZoraSpacing.unit / 2))
                .padding(.bottom, ZoraSpacing.card)
            }
        }
    }
}
