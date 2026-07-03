import SwiftUI
import UIKit

struct HeroBadge: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(ZoraBrand.secondaryForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .zoraSurface(.subtle, cornerRadius: ZoraRadius.control)
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
                .foregroundStyle(ZoraBrand.ink)
                .frame(width: 23, height: 23)
                .background(ZoraBrand.foreground, in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZoraBrand.foreground)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(ZoraBrand.foreground.opacity(0.5))
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
                        .foregroundStyle(ZoraBrand.foreground.opacity(0.28))
                }

                Text(text)
                    .foregroundStyle(ZoraBrand.foreground.opacity(0.78))
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
                        .foregroundStyle(didCopy ? ZoraBrand.success : ZoraBrand.foreground.opacity(0.76))
                        .frame(width: 28, height: 28)
                        .background(ZoraBrand.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                .fill(ZoraBrand.foreground.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ZoraBrand.foreground.opacity(0.08), lineWidth: 1)
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
                .foregroundStyle(ZoraBrand.foreground)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZoraBrand.foreground.opacity(0.5))

                content
                    .font(.body.weight(.medium))
                    .foregroundStyle(ZoraBrand.foreground)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(ZoraBrand.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ZoraBrand.foreground.opacity(0.08), lineWidth: 1)
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
                .foregroundStyle(ZoraBrand.foreground.opacity(0.76))
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

struct OnboardingStepHeader: View {
    let stepNumber: Int
    let icon: String
    let title: String
    let description: String

    private let accent = ZoraBrand.foreground

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ZoraBrand.foreground)
                .frame(width: 80, height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(ZoraBrand.foreground.opacity(0.06))
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
                    .foregroundStyle(ZoraBrand.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(ZoraBrand.foreground.opacity(0.45))
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
                    .foregroundStyle(ZoraBrand.foreground.opacity(0.82))
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
            .buttonStyle(ZoraPrimaryButtonStyle(cornerRadius: ZoraRadius.small))
            .accessibilityLabel(didCopyRecently ? String(localized: "Agent setup prompt copied") : String(localized: "Copy agent setup prompt"))
        }
        .padding(ZoraSpacing.card)
        .zoraSurface(.subtle, cornerRadius: ZoraRadius.card)
    }
}

struct OnboardingPageIndicator: View {
    let pageCount: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? ZoraBrand.foreground : ZoraBrand.foreground.opacity(0.18))
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
    }
}
