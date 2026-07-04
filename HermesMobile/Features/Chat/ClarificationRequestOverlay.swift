import SwiftUI

struct ClarificationRequestOverlay: View {
    let prompt: ClarificationPromptState
    let isResponding: Bool
    let errorMessage: String?
    let bottomPadding: CGFloat
    let onSubmit: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(colorScheme == .dark ? 0.24 : 0.18)
                .ignoresSafeArea()

            ClarificationRequestCard(
                prompt: prompt,
                isResponding: isResponding,
                errorMessage: errorMessage,
                onSubmit: onSubmit
            )
                .padding(.horizontal, 16)
                .padding(.bottom, bottomPadding)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
        .accessibilityElement(children: .contain)
    }
}

struct ClarificationRequestCard: View {
    let prompt: ClarificationPromptState
    let isResponding: Bool
    let errorMessage: String?
    let onSubmit: (String) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var submitButtonSize: CGFloat = 40
    @State private var draftResponse = ""

    var body: some View {
        card
            .accessibilityElement(children: .contain)
    }

    private var card: some View {
        cardSurface
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 18, x: 0, y: 12)
    }

    @ViewBuilder
    private var cardSurface: some View {
        if reduceTransparency {
            cardContent
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                )
                .overlay(cardBorder)
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                cardContent
                    .glassEffect(.regular.tint(cardTint), in: .rect(cornerRadius: cardCornerRadius))
            }
        } else {
            cardContent
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(cardBorder)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clarification Required")
                    .font(.headline)

                if prompt.pendingCount > 1 {
                    Text("1 of \(prompt.pendingCount) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            expirationView
        }
    }

    private var question: some View {
        Text(prompt.question)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(questionBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private var choicesList: some View {
        VStack(spacing: 8) {
            ForEach(prompt.choices, id: \.self) { choice in
                choiceButton(choice)
            }
        }
    }

    private var responseField: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type a response", text: $draftResponse, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .tint(actionButtonBackground)
                .background(textFieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(textFieldBorder)
                .disabled(isResponding || prompt.isExpired)

            Button {
                submitDraft()
            } label: {
                submitButtonLabel
                    .frame(width: submitButtonSize, height: submitButtonSize)
                    .background(actionButtonBackground)
                    .foregroundStyle(actionButtonForeground)
                    .clipShape(Circle())
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(isResponding || prompt.isExpired || trimmedDraft.isEmpty)
            .accessibilityLabel("Submit clarification")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let errorMessage = nonEmpty(errorMessage) {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var expirationView: some View {
        if prompt.pending.expiresAt != nil || prompt.pending.timeoutSeconds != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                expirationBadge(now: context.date)
            }
        }
    }

    private func expirationBadge(now: Date) -> some View {
        let remaining = remainingSeconds(now: now)
        let fraction = remainingFraction(now: now)

        return VStack(alignment: .trailing, spacing: 5) {
            Text(expirationText(remaining: remaining))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.10))
                    Capsule()
                        .fill(progressFill)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(width: 68, height: 4)
            .accessibilityLabel("Clarification expiration")
            .accessibilityValue(expirationText(remaining: remaining))
        }
    }

    private var trimmedDraft: String {
        draftResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            question

            if !prompt.choices.isEmpty {
                choicesList
            }

            responseField
            footer
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private var submitButtonLabel: some View {
        if isResponding {
            ProgressView()
                .tint(actionButtonForeground)
                .scaleEffect(0.82)
        } else {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    @ViewBuilder
    private func choiceButton(_ choice: String) -> some View {
        Button {
            onSubmit(choice)
        } label: {
            Text(choice)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .foregroundStyle(.primary)
                .choiceButtonSurface(reduceTransparency: reduceTransparency)
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isResponding || prompt.isExpired)
    }

    private var questionBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04)
    }

    private var textFieldBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.primary.opacity(colorScheme == .dark ? 0.13 : 0.10), lineWidth: 1)
    }

    private var actionButtonBackground: Color {
        if isResponding || prompt.isExpired || trimmedDraft.isEmpty {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }

        return colorScheme == .dark ? .white : .black
    }

    private var actionButtonForeground: Color {
        if isResponding || prompt.isExpired || trimmedDraft.isEmpty {
            return Color(.secondaryLabel)
        }

        return colorScheme == .dark ? .black : .white
    }

    private var progressFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.58)
    }

    private var cardTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.16)
    }

    private var cardCornerRadius: CGFloat {
        24
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1)
    }

    private func submitDraft() {
        let value = trimmedDraft
        guard !value.isEmpty else { return }
        onSubmit(value)
    }

    private func remainingSeconds(now: Date) -> TimeInterval? {
        guard let expiresAt = prompt.pending.expiresAt else { return nil }
        return max(0, expiresAt - now.timeIntervalSince1970)
    }

    private func remainingFraction(now: Date) -> CGFloat {
        guard let remaining = remainingSeconds(now: now),
              let timeoutSeconds = prompt.pending.timeoutSeconds,
              timeoutSeconds > 0
        else {
            return 1
        }

        return CGFloat(min(1, max(0, remaining / Double(timeoutSeconds))))
    }

    private func expirationText(remaining: TimeInterval?) -> String {
        guard let remaining else {
            guard let timeoutSeconds = prompt.pending.timeoutSeconds else { return "" }
            return String(localized: "Timeout \(Self.durationText(Double(timeoutSeconds)))")
        }

        if remaining <= 0 {
            return String(localized: "Expired")
        }

        return String(localized: "\(Self.durationText(remaining)) left")
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        let minutes = value / 60
        let seconds = value % 60

        guard minutes > 0 else {
            return "\(seconds)s"
        }

        return "\(minutes)m \(seconds)s"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension View {
    @ViewBuilder
    func choiceButtonSurface(reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        } else if #available(iOS 26.0, *) {
            // Fixed corner radius (not .capsule): a capsule's radius grows with the
            // button's height, so on tall multi-line options the curved ends bow
            // inward and clip the text. A fixed radius keeps the outline clear of
            // the label at any line count and matches the fallbacks below.
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.primary.opacity(0.10), lineWidth: 1)
                )
        }
    }
}
