import SwiftUI

/// The two-up grid of window totals under the chart. It reflows to one column at
/// accessibility text sizes, where two cells no longer fit side by side.
struct UsageTotalsGrid: View {
    let cells: [UsageTotalsCell]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: count)
    }

    var body: some View {
        UsageCard(title: String(localized: "Totals")) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(cells) { cell in
                    UsageMetricCell(cell: cell)
                }
            }
        }
    }
}

/// One label / value / detail stack. It reads as a single VoiceOver element so
/// the grid does not turn into three swipes per figure.
private struct UsageMetricCell: View {
    let cell: UsageTotalsCell

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Text(cell.value)
                .font(AppFont.title3(weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let detail = cell.detail {
                Text(detail)
                    .font(AppFont.caption2())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
