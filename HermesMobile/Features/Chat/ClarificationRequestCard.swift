import SwiftUI
import UIKit

/// The clarification request pinned above the composer while the agent waits
/// for an answer. The collapsed bar is the permanent footprint: its measured
/// height feeds the transcript's bottom inset. The expanded card is an overlay
/// that rises from the bar's bottom edge, so opening or closing it never moves
/// the transcript. A new request always arrives expanded.
struct ClarificationRequestInset: View {
    let prompt: ClarificationPromptState
    let isResponding: Bool
    let isStopping: Bool
    let errorMessage: String?
    let isHapticsEnabled: Bool
    let onSubmit: (String) -> Void
    let onStop: () -> Void
    /// Collapsing hides the response field, so the keyboard goes with it.
    let onDismissKeyboard: () -> Void
    /// The bar's height, the only part of this view that takes layout space.
    let onFootprintChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    // Lives here rather than in the card so a typed answer survives collapse.
    @State private var draftResponse = ""

    var body: some View {
        ClarificationRequestBar(
            prompt: prompt,
            isStopping: isStopping,
            onExpand: { setExpanded(true) },
            onStop: onStop
        )
        .accessibilityHidden(isExpanded)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onFootprintChange(height)
        }
        .overlay(alignment: .bottom) {
            // Clip window with its bottom edge on the bar's bottom edge: the
            // opaque card slides its own height down through it, revealing the
            // transcript and then the bar only where it has physically left.
            // No crossfade, and nothing is drawn over the composer below.
            ZStack(alignment: .bottom) {
                if isExpanded {
                    ClarificationRequestCard(
                        prompt: prompt,
                        isResponding: isResponding,
                        errorMessage: errorMessage,
                        draftResponse: $draftResponse,
                        onSubmit: onSubmit,
                        onCollapse: { setExpanded(false) }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .clipped()
        }
        .onChange(of: prompt.id, initial: true) {
            announceRequest()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        if !expanded {
            onDismissKeyboard()
        }
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
        withAnimation(ChatMotion.clarificationToggle(reduceMotion: reduceMotion)) {
            isExpanded = expanded
        }
    }

    /// One announcement per request; re-renders and toggles stay silent.
    private func announceRequest() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let announcement = String(localized: "Input needed: \(ClarificationRequestBar.summary(for: prompt.question))")
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// One-line footprint of a pending clarification: what is being asked, a way
/// back into the card, and Stop for when the run should end instead.
struct ClarificationRequestBar: View {
    let prompt: ClarificationPromptState
    let isStopping: Bool
    let onExpand: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var stopButtonSize: CGFloat = 32

    /// The first non-empty line of a question, so a multi-line prompt reads
    /// as one line on the bar.
    static func summary(for question: String) -> String {
        question
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Input needed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(Self.summary(for: prompt.question))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand clarification")
            .accessibilityValue(Self.summary(for: prompt.question))

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: stopButtonSize, height: stopButtonSize)
                    .background(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .foregroundStyle(.red)
                    .clipShape(Circle())
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(isStopping)
            .accessibilityLabel("Stop response")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .clarificationSurface(cornerRadius: 22)
        .accessibilityElement(children: .contain)
    }
}

struct ClarificationRequestCard: View {
    let prompt: ClarificationPromptState
    let isResponding: Bool
    let errorMessage: String?
    @Binding var draftResponse: String
    let onSubmit: (String) -> Void
    let onCollapse: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var submitButtonSize: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var collapseButtonSize: CGFloat = 28
    @State private var bodyContentHeight: CGFloat?

    /// Beyond this the question and choices scroll inside the card, so a long
    /// prompt cannot push the response field off screen. Sized to fit a short
    /// question with four choices without scrolling.
    private let bodyHeightCap: CGFloat = 300

    var body: some View {
        cardContent
            .frame(maxWidth: 560, alignment: .leading)
            .clarificationSurface(cornerRadius: 24)
            // Ideal height regardless of what the bar-sized overlay proposes.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
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

            collapseButton
        }
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: collapseButtonSize, height: collapseButtonSize)
                .background(.primary.opacity(0.08))
                .foregroundStyle(.secondary)
                .clipShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel("Collapse clarification")
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

    /// Question plus choices, scrolling only once they outgrow the cap.
    @ViewBuilder
    private var scrollableBody: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            question

            if !prompt.choices.isEmpty {
                choicesList
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            bodyContentHeight = height
        }

        if let bodyContentHeight, bodyContentHeight > bodyHeightCap {
            ScrollView {
                content
            }
            .frame(height: bodyHeightCap)
        } else {
            content
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
                .disabled(isResponding)

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
            .disabled(isResponding || trimmedDraft.isEmpty)
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
            scrollableBody
            responseField
            footer
        }
        .padding(16)
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
        .disabled(isResponding)
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
        if isResponding || trimmedDraft.isEmpty {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }

        return colorScheme == .dark ? .white : .black
    }

    private var actionButtonForeground: Color {
        if isResponding || trimmedDraft.isEmpty {
            return Color(.secondaryLabel)
        }

        return colorScheme == .dark ? .black : .white
    }

    private var progressFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.58)
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
    /// Opaque on purpose: the bar and card float over live transcript text,
    /// and a translucent surface would render the question on top of whatever
    /// message happens to sit underneath.
    func clarificationSurface(cornerRadius: CGFloat) -> some View {
        background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        )
    }

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
