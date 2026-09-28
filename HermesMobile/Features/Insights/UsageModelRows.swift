import SwiftUI

/// Every model the server reported for the window, in the order it returned them
/// (cost descending). There is no provider dot: the insights handler has no
/// provider dimension to draw one from.
struct UsageModelsCard: View {
    let models: [InsightsModelBreakdown]
    /// Whether the window has any priced usage at all. When it does not, the rows
    /// lead with token share instead of a row of identical "0% of cost".
    let hasCost: Bool

    var body: some View {
        SectionCard(title: String(localized: "By model")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    UsageModelRow(model: model, hasCost: hasCost)
                }
            }
        }
    }
}

private struct UsageModelRow: View {
    let model: InsightsModelBreakdown
    let hasCost: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.model ?? String(localized: "Unknown Model"))
                    .font(AppFont.subheadline(weight: .medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)

                Text(secondaryLine)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let cost = model.cost, cost > 0 {
                Text(usageFormattedCost(cost))
                    .font(AppFont.subheadline(weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var secondaryLine: String {
        var parts: [String] = []

        if hasCost, let costShare = model.costShare {
            parts.append(String(localized: "\(costShare)% of cost"))
        } else if let tokenShare = model.tokenShare {
            parts.append(String(localized: "\(tokenShare)% of tokens"))
        }

        parts.append(String(localized: "\(usageFormattedTokens(model.totalTokens ?? 0)) tokens"))
        parts.append(String(localized: "\(model.sessions ?? 0) sessions"))

        if let cacheHitPercent = model.cacheHitPercent {
            parts.append(String(localized: "\(insightsFormattedPercent(cacheHitPercent)) cache"))
        }

        return parts.joined(separator: " · ")
    }
}

/// The heaviest sessions, by tokens. Only reachable on the local-metadata
/// fallback, where the server never told us about models.
struct UsageTopSessionsCard: View {
    let sessions: [SessionSummary]

    var body: some View {
        SectionCard(title: String(localized: "Top Sessions")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sessions.prefix(10)) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title ?? String(localized: "Untitled Session"))
                            .font(AppFont.subheadline(weight: .medium))
                            .lineLimit(1)

                        Text(detail(for: session))
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func detail(for session: SessionSummary) -> String {
        let total = (session.inputTokens ?? 0) + (session.outputTokens ?? 0)
        let tokens = String(localized: "\(usageFormattedTokens(total)) tokens")

        guard let cost = session.estimatedCost, cost > 0 else { return tokens }
        return "\(tokens) · \(usageFormattedCost(cost))"
    }
}
