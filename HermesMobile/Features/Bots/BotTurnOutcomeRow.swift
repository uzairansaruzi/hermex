import SwiftUI

/// Why the last Bot turn failed, or a warning about how it ended, drawn under the
/// turn in Bot Chat (design C, #878). A failure shows its title, the host's raw
/// error, when a rate limit resets, and Retry or the billing page; a warning shows
/// the host's own sentence. Static: nothing animates, and a passed reset time
/// simply drops on the next redraw.
struct BotTurnOutcomeRow: View {
    /// The host-retained failure (`BotConversation.turnFailure`).
    let failure: HermesTurnOutcome?
    /// The live-only billing link and warning (`BotConversation.turnNotice`).
    let notice: HermesTurnOutcome?
    let offersRetry: Bool
    let mayRetry: Bool
    let onRetry: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure {
                block(systemImage: "xmark.circle.fill", tint: .red, title: Self.title(for: failure),
                      detail: failure.error, resetsAt: failure.surface?.resetsAt) {
                    failureButtons
                }
            }
            if let warning = notice?.warning {
                // The host's words, verbatim: a fixed sentence could lie about a new warning.
                block(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                      title: String(localized: "Reply shown but not saved"), detail: warning, resetsAt: nil) {
                    EmptyView()
                }
            }
        }
    }

    /// Hermex's title for a failure: the host's own sentence when it sends one, then
    /// the custom endpoint when that is what failed, then a title for the code where
    /// the fix differs, then one for the layer that failed. The host's wording
    /// without its slash commands (`user_messages.py`).
    static func title(for failure: HermesTurnOutcome) -> String {
        if let message = failure.surface?.message { return message }
        // The host files a custom or local endpoint's timeout under `endpoint` so the
        // user checks that endpoint on the Mac, not the provider.
        if failure.surface?.layer == "endpoint" { return String(localized: "Your custom model endpoint did not answer") }
        switch failure.surface?.code ?? failure.failureReason {
        case "rate_limit", "upstream_rate_limit": return String(localized: "The model provider is rate-limiting requests")
        case "context_overflow": return String(localized: "The conversation is too long for this model")
        case "payload_too_large": return String(localized: "The request was too large for this model")
        case "model_not_found": return String(localized: "The model provider does not know this model")
        case "content_policy_blocked": return String(localized: "The model provider refused this request (content policy)")
        case "timeout": return String(localized: "The model provider did not answer in time")
        case "overloaded": return String(localized: "The model provider is overloaded")
        case "server_error": return String(localized: "The model provider had an internal error")
        default: break
        }
        switch failure.surface?.layer {
        case "auth": return String(localized: "The model provider rejected the API key")
        case "billing": return String(localized: "The model provider reports no credit left")
        case "streaming": return String(localized: "The connection to the model provider dropped mid-reply")
        case "disk": return String(localized: "The disk is full, so Hermes could not save the turn")
        case "gateway": return String(localized: "Hermes hit an internal error while running this turn")
        case "provider": return String(localized: "The model provider returned an error")
        default: return String(localized: "The turn failed")
        }
    }

    /// One recessed block: icon and title, then the detail and reset time under the
    /// title, then any buttons across the full width.
    private func block(systemImage: String, tint: Color, title: String, detail: String?, resetsAt: Date?,
                       @ViewBuilder buttons: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        // Raw provider text is often a JSON blob: capped, and selectable to copy.
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    if let resetsAt, resetsAt > Date() {
                        Label(Self.resetLine(resetsAt), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            buttons()
        }
        .pendingRequestBlockSurface()
    }

    @ViewBuilder private var failureButtons: some View {
        let billingURL = notice?.billingURL
        if offersRetry || billingURL != nil {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if offersRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.chatDecision(.secondary))
                    .disabled(!mayRetry)
                }
                if let billingURL {
                    // Safari, not an in-app sheet, as for connector links (#770): the
                    // provider sign-in lives there. Opened directly, past the link router.
                    Button { UIApplication.shared.open(billingURL) } label: {
                        Label("Open billing page", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.chatDecision(.secondary))
                }
            }
        }
    }

    /// "Limit resets at 14:05" in the user's locale, with the date when it is not today.
    private static func resetLine(_ date: Date) -> String {
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Limit resets at \(time)")
    }
}
