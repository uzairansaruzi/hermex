import SwiftUI

struct ProviderLimitsSection: View {
    let cards: [ProviderLimitCard]
    let isLoading: Bool
    let refreshFailed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limits")
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 4)

            if refreshFailed, !cards.isEmpty {
                refreshFailureNotice
            }

            if !cards.isEmpty {
                ForEach(cards) { card in
                    ProviderLimitsCard(card: card)
                }
            } else if isLoading {
                ProviderLimitsPlaceholderCard()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: cards)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: refreshFailed)
    }

    private var refreshFailureNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppFont.caption())
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Couldn't refresh limits. Showing the last values loaded.")
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(.appPrimary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderLimitsPlaceholderCard: View {
    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Provider")
                    .font(AppFont.headline())
                    .foregroundStyle(.appPrimary)
                    .padding(.bottom, 14)

                row

                row
                    .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .redacted(reason: .placeholder)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Limits"))
        .accessibilityValue(Text("Loading"))
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Session")
                    .font(AppFont.body())

                Spacer(minLength: 8)

                Text(verbatim: "100% left")
                    .font(AppFont.body(weight: .semibold))
            }

            ProviderLimitBar(fraction: 0, tint: .normal)

            Text(verbatim: "Resets in 12h 00m")
                .font(AppFont.caption())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderLimitsCard: View {
    let card: ProviderLimitCard

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let now = Date()

        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header

                ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                    ProviderLimitRowView(row: row, now: now)
                        .padding(.top, index > 0 ? 28 : 0)
                }

                if let updated = providerLimitUpdatedText(card.updatedAt, now: now) {
                    Divider()
                        .padding(.vertical, 14)

                    Text(updated)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = Text(card.title)
            .font(AppFont.headline())
            .foregroundStyle(.appPrimary)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    planCapsule
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    planCapsule
                }
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var planCapsule: some View {
        if let plan = card.plan {
            Text(plan)
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay {
                    Capsule()
                        .stroke(Color(.appText).opacity(0.18), lineWidth: 0.8)
                }
        }
    }
}

private struct ProviderLimitRowView: View {
    let row: ProviderLimitRow
    let now: Date

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let resetText = providerLimitResetText(row.resetAt, now: now)

        VStack(alignment: .leading, spacing: 8) {
            amountRow

            if let fraction = row.fraction {
                ProviderLimitBar(fraction: fraction, tint: tint)
            }

            if let secondary = resetText {
                Label {
                    Text(secondary)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                }
            } else if let note = row.note {
                Text(note)
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var amountRow: some View {
        let label = Text(row.label)
            .font(AppFont.body())
            .foregroundStyle(.appPrimary)

        let amount = Group {
            if let amount = row.amount {
                Text(amount)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(tintColor)
                    .monospacedDigit()
            }
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                label
                amount
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                Spacer(minLength: 8)
                amount
            }
        }
    }

    private var tint: ProviderLimitTint {
        providerLimitTint(remainingPercent: row.remainingPercent)
    }

    private var tintColor: Color {
        switch tint {
        case .normal:
            .accentColor
        case .warning:
            .orange
        case .critical:
            .red
        }
    }

    private var accessibilityLabel: String {
        [
            row.label,
            row.amount,
            providerLimitResetText(row.resetAt, now: now, width: .wide) ?? row.note
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct ProviderLimitBar: View {
    let fraction: Double
    let tint: ProviderLimitTint

    var body: some View {
        Capsule()
            .fill(Color(.appText).opacity(0.14))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 8 : 0))
                }
            }
            .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch tint {
        case .normal:
            .accentColor
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}
