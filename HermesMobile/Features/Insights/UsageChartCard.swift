import Charts
import SwiftUI

/// The Usage screen's headline card: the window figure, the metric toggle, the
/// bar chart, and the edge labels beneath it.
///
/// Dragging across the chart replaces the hero with the touched bucket's own
/// figures and restores the window total on release, which is what lets the old
/// "Recent Daily Tokens" list go away without losing per-day detail.
struct UsageChartCard: View {
    let buckets: [UsageBucket]
    @Binding var metric: UsageMetric
    let showsMetricToggle: Bool
    let windowTotal: UsageHeroFigure
    let hourlyNote: String?
    let chartAccessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedBucketID: Int?

    private static let chartHeight: CGFloat = 180

    var body: some View {
        UsageCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                chart
                footer

                if let hourlyNote {
                    Text(hourlyNote)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: buckets) { _, _ in
            selectedBucketID = nil
        }
    }

    // MARK: - Header

    private var hero: UsageHeroFigure {
        guard let selectedBucketID, let bucket = buckets.first(where: { $0.id == selectedBucketID }) else {
            return windowTotal
        }
        return .selection(bucket, metric: metric)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            let hero = hero

            VStack(alignment: .leading, spacing: 2) {
                Text(hero.label)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)

                Text(hero.value)
                    .font(AppFont.title(weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(hero.caption)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if showsMetricToggle {
                Picker(String(localized: "Metric"), selection: $metric) {
                    ForEach(UsageMetric.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Chart

    private var hasActivity: Bool {
        buckets.contains(where: \.hasActivity)
    }

    @ViewBuilder
    private var chart: some View {
        if hasActivity {
            Chart {
                ForEach(buckets) { bucket in
                    ForEach(Array(bucket.segments(for: metric).enumerated()), id: \.offset) { index, layer in
                        BarMark(
                            x: .value("Bucket", bucket.label),
                            y: .value(layer.segment.title, layer.value)
                        )
                        .foregroundStyle(layer.segment.color)
                        .opacity(selectedBucketID == nil || selectedBucketID == bucket.id ? 1 : 0.3)
                        // One VoiceOver element per bar: the first layer speaks for
                        // the whole bucket and the rest stay out of the way.
                        .accessibilityLabel(index == 0 ? bucket.label : "")
                        .accessibilityValue(index == 0 ? bucket.accessibilityValue : "")
                        .accessibilityHidden(index != 0)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: Self.chartHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: buckets)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(selectionGesture(proxy: proxy, geometry: geometry))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(chartAccessibilityLabel)
        } else {
            Text("No activity in this window.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.chartHeight)
        }
    }

    /// Press and scrub to inspect a bar, release to go back to the window total.
    ///
    /// The press comes first on purpose: a bare drag would eat the enclosing
    /// scroll view's vertical swipes, so the page would stop scrolling wherever
    /// the chart is.
    private func selectionGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { phase in
                guard case let .second(_, drag?) = phase, let plotFrame = proxy.plotFrame else { return }
                let plotOrigin = geometry[plotFrame].origin.x
                guard let label: String = proxy.value(atX: drag.location.x - plotOrigin) else { return }
                selectedBucketID = buckets.first { $0.label == label }?.id
            }
            .onEnded { _ in
                selectedBucketID = nil
            }
    }

    // MARK: - Footer

    private var legendSegments: [UsageChartSegment] {
        usageChartLegendSegments(buckets: buckets, metric: metric)
    }

    /// The legend sits between the two edge labels at normal text sizes and drops
    /// to its own row at accessibility sizes, where three swatches and two dates
    /// can no longer share a line.
    private var showsLegendInline: Bool {
        !legendSegments.isEmpty && !dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                edgeLabel(buckets.first?.label ?? "", alignment: .leading)

                if showsLegendInline {
                    legend
                }

                edgeLabel(buckets.last?.label ?? "", alignment: .trailing)
            }

            if !legendSegments.isEmpty && !showsLegendInline {
                legend
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(AppFont.caption2())
        .foregroundStyle(.secondary)
        .accessibilityHidden(!hasActivity)
    }

    private func edgeLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// Sized to its content so the flexible edge labels absorb the slack instead
    /// of squeezing "Cache read" into one character per line.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(legendSegments) { segment in
                HStack(spacing: 4) {
                    Circle()
                        .fill(segment.color)
                        .frame(width: 7, height: 7)

                    Text(segment.title)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}
