import SwiftUI

/// Onboarding's one page (#1540): "Add your server" opens the Add Server sheet, and "I don't
/// have one yet" the setup pages.
struct OnboardingWelcomePage: View {
    let addServer: () -> Void
    let setUp: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var iconSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 108 : 124
    }

    private var iconCornerRadius: CGFloat {
        iconSize * 0.22
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black.ignoresSafeArea())
        // The buttons stay in reach while large text scrolls the page.
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: addServer) {
                Text("Add your server")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())

            Button(action: setUp) {
                Text("I don’t have one yet")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(Color.black)
    }

    private var content: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

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
                    // A background takes no layout, so a short display (iPhone Duo folded) gives the
                    // glow's overflow to the copy instead of scrolling it behind the buttons.
                    .background {
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
                        }
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

                    Text("Connect to your self-hosted server over a private network, such as Tailscale or NetBird.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        HeroBadge(systemImage: "lock.shield.fill", title: String(localized: "Password protected"))
                        HeroBadge(systemImage: "network", title: String(localized: "Private network ready"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
    }
}
