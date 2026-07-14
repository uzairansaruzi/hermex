import SwiftUI
import UIKit

struct HeroBadge: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct SetupStepRow: View {
    let number: String
    let title: String
    let subtitle: String
    var command: String?
    var commandPrefix: String? = "$"
    var copyValue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 23, height: 23)
                .background(Color(red: 1.0, green: 0.74, blue: 0.10), in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if let command {
                    OnboardingCommandPill(text: command, prefix: commandPrefix, copyValue: copyValue)
                }
            }
        }
    }
}

struct OnboardingCommandPill: View {
    let text: String
    var prefix: String? = "$"
    var copyValue: String?
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                if let prefix {
                    Text("\(prefix) ")
                        .foregroundStyle(.white.opacity(0.28))
                }

                Text(text)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let copyValue {
                Button {
                    UIPasteboard.general.string = copyValue
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(didCopy ? Color(red: 0.45, green: 0.92, blue: 0.56) : .white.opacity(0.76))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? String(localized: "Copied Web UI repository link") : String(localized: "Copy Web UI repository link"))
            }
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct OnboardingField<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.10))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))

                content
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct OnboardingStatusBanner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(tint)
                    .padding(.top, 1)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }

            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(Color(red: 1.0, green: 0.74, blue: 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct OnboardingStepHeader: View {
    let stepNumber: Int
    let icon: String
    let title: String
    let description: String

    private let accent = Color(red: 1.0, green: 0.74, blue: 0.10)

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("STEP \(stepNumber)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent.opacity(0.8))
                    .kerning(1.5)

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct OnboardingAgentPromptCard: View {
    let prompt: String
    @Binding var hasCopied: Bool
    @State private var didCopyRecently = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical, showsIndicators: true) {
                Text(prompt)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)

            Button {
                UIPasteboard.general.string = prompt
                hasCopied = true
                HapticButtonHaptics.tap(style: .light, isEnabled: isHapticsEnabled)
                withAnimation(.easeInOut(duration: 0.2)) {
                    didCopyRecently = true
                }
            } label: {
                Label(didCopyRecently ? String(localized: "Copied") : String(localized: "Copy prompt"), systemImage: didCopyRecently ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityLabel(didCopyRecently ? String(localized: "Agent setup prompt copied") : String(localized: "Copy agent setup prompt"))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onChange(of: prompt) {
            didCopyRecently = false
        }
    }
}

struct OnboardingNetworkProviderPicker: View {
    @Binding var selection: PrivateNetworkProvider

    private let accent = Color(red: 1.0, green: 0.74, blue: 0.10)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PrivateNetworkProvider.allCases) { provider in
                Button {
                    selection = provider
                } label: {
                    Text(provider.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == provider ? Color.black : Color.white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selection == provider ? accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == provider ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Private network")
        .accessibilityHint("Changes the setup prompt and iPhone installation instructions.")
    }
}

struct OnboardingPageIndicator: View {
    let pageCount: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.white : Color.white.opacity(0.18))
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.84))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
