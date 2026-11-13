import SwiftUI
import UIKit

struct HeroBadge: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption(weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.subheadline(weight: .semibold))
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
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(accent.opacity(0.8))
                    .kerning(1.5)

                Text(title)
                    .font(AppFont.fixed(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(AppFont.subheadline())
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
    let isCopied: Bool
    let onCopy: () -> Void
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                ChatHaptics.copied(isEnabled: isHapticsEnabled)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    onCopy()
                }
            } label: {
                Label(isCopied ? String(localized: "Copied") : String(localized: "Copy prompt"), systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(AppFont.subheadline(weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .accessibilityLabel(isCopied ? String(localized: "Agent setup prompt copied") : String(localized: "Copy agent setup prompt"))
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
    }
}

struct OnboardingPageIndicator: View {
    let pageCount: Int
    let currentPage: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.white : Color.white.opacity(0.18))
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
    }
}
