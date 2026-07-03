import SwiftUI

struct OnboardingFeaturesPage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let features: [(icon: String, color: Color, title: String, subtitle: String)] = [
        ("bubble.left.and.bubble.right.fill", ZoraBrand.foreground, String(localized: "Chat with your Zora agent from iPhone"), String(localized: "Drive conversations from anywhere on your tailnet.")),
        ("list.bullet.rectangle.portrait.fill", ZoraBrand.success, String(localized: "Manage sessions, tasks, and files remotely"), String(localized: "Browse workspaces and stay on top of agent work.")),
        ("mic.fill", ZoraBrand.warning, String(localized: "Voice input and mobile-friendly composer controls"), String(localized: "Compose naturally with touch-first controls.")),
        ("checkmark.shield.fill", ZoraBrand.paper, String(localized: "Review approvals and clarifications inline"), String(localized: "Respond to agent prompts without switching apps.")),
        ("server.rack", ZoraBrand.terracotta, String(localized: "Self-hosted: your machine, your tailnet"), String(localized: "Your Hermes Web UI stays on hardware you control."))
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 28 : 36) {
                VStack(spacing: 10) {
                    Text("What you get")
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 26 : 28, weight: .bold))
                        .foregroundStyle(ZoraBrand.foreground)

                    Text("Your Zora agent, reachable from iPhone over Tailscale.")
                        .font(.subheadline)
                        .foregroundStyle(ZoraBrand.tertiaryForeground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, ZoraSpacing.section)

                VStack(spacing: 16) {
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        OnboardingFeatureRow(
                            icon: feature.icon,
                            color: feature.color,
                            title: feature.title,
                            subtitle: feature.subtitle
                        )
                    }
                }
            }
            .padding(.horizontal, ZoraSpacing.screenInset + (ZoraSpacing.unit / 2))
            .padding(.bottom, ZoraSpacing.section)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct OnboardingFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZoraBrand.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ZoraBrand.tertiaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
