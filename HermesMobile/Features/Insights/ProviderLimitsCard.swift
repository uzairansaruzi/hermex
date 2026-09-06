import SwiftUI

/// The "Limits" group at the top of the Usage screen (#415): one card per
/// provider that reported a usable quota, or a placeholder card while the first
/// probes are still running. The caller omits the group entirely when there are
/// no cards and nothing is loading, which is how every failed or unsupported
/// probe disappears.
struct ProviderLimitsSection: View {
    let cards: [ProviderLimitCard]
    /// Drives the placeholder, and only while `cards` is empty: a refresh with
    /// cards already on screen keeps them rather than blanking the group.
    let isLoading: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Limits")
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if !cards.isEmpty {
                ForEach(cards) { card in
                    ProviderLimitsCard(card: card)
                }
            } else if isLoading {
                ProviderLimitsPlaceholderCard()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: cards)
    }
}

/// Holds the Limits slot open while the first quota probes are in flight, so the
/// real cards replace a reserved space instead of appearing above the analytics
/// and pushing the screen down a second after it settles (#415).
///
/// The sample text is redacted and never spoken; its only job is to be about as
/// tall as one account-limits card. Nothing here animates or repaints.
private struct ProviderLimitsPlaceholderCard: View {
    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Provider")
                    .font(AppFont.headline())
                    .foregroundStyle(.primary)
                    .padding(.bottom, 14)

                row

                Divider()
                    .padding(.vertical, 14)

                row
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .redacted(reason: .placeholder)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Limits"))
        .accessibilityValue(Text("Loading"))
    }

    /// Mirrors `ProviderLimitRowView`: an amount line, the bar, and a caption.
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

/// One provider's card: a header, a row per limit window, and a footer saying
/// how old the numbers are. Every relative time is computed while the body runs
/// — nothing here ticks, animates, or repaints on its own.
struct ProviderLimitsCard: View {
    let card: ProviderLimitCard

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // One `Date()` for the whole card so its rows and footer agree.
        let now = Date()

        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header

                ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 14)
                    }

                    ProviderLimitRowView(row: row, now: now)
                }

                if let updated = providerLimitUpdatedText(card.updatedAt, now: now) {
                    Divider()
                        .padding(.vertical, 14)

                    Text(updated)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = Text(card.title)
            .font(AppFont.headline())
            .foregroundStyle(.primary)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Two lines at accessibility sizes: the capsule would otherwise
                // squeeze the provider name to a couple of characters.
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
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
                }
        }
    }
}

/// One limit row: the label, the bold remaining amount, the bar, and either a
/// reset countdown or a static usage note.
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
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            } else if let note = row.note {
                Text(note)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(.primary)

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

    /// Spoken as one phrase, with the countdown spelled out — VoiceOver reads
    /// the on-screen "23h 35m" as letters, so the wide form is substituted here.
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

/// The remaining-balance bar. Deliberately unanimated: it is redrawn only when
/// a load replaces the card, so there is nothing for Reduce Motion to suppress
/// and nothing repainting between loads.
private struct ProviderLimitBar: View {
    let fraction: Double
    let tint: ProviderLimitTint

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.14))
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
