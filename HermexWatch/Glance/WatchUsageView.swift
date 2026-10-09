import Charts
import SwiftUI
import HermexWatchRoot
import WatchShared

// MARK: - Usage

/// "What did I spend?" Spend first, then the daily token shape, the totals,
/// and which models it went to. Provider limits and goals stay on iPhone.
struct WatchUsageListView: View {
    @Bindable var model: WatchRootModel
    @State private var usage: WatchInsightsAggregate?
    @State private var phase: WatchGlancePhase = .loading
    @State private var days = 30

    var body: some View {
        List {
            Picker("Period", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .accessibilityHint("Changes the window the totals cover.")

            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: usage == nil,
                emptyTitle: "No usage yet",
                emptySymbol: "chart.bar",
                retry: reload
            )
            if let usage {
                spendHeader(usage)

                if usage.dailyTokens.items.contains(where: { $0 > 0 }) {
                    dailyChart(usage.dailyTokens.items)
                }

                Section {
                    stat("Tokens", value: usage.totalTokens, systemImage: "number")
                    stat("Input", value: usage.totalInputTokens, systemImage: "arrow.down")
                    stat("Output", value: usage.totalOutputTokens, systemImage: "arrow.up")
                    stat("Sessions", value: usage.totalSessions, systemImage: "bubble.left.and.bubble.right")
                    stat("Messages", value: usage.totalMessages, systemImage: "text.bubble")
                }

                if let breakdown = usage.modelUsage?.items, !breakdown.isEmpty {
                    Section("Models") {
                        ForEach(breakdown, id: \.name) { model in
                            modelRow(model)
                        }
                    }
                } else if !usage.models.items.isEmpty {
                    Section("Models") {
                        ForEach(usage.models.items, id: \.self) { name in
                            Text(name)
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: days) { await reload() }
        .refreshable { await reload() }
    }

    private func spendHeader(_ usage: WatchInsightsAggregate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last \(usage.days.value) days")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(usage.totalCost, format: .currency(code: "USD"))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text("estimated spend")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    /// Static bars, no animation, no selection: one look answers "was today
    /// unusual?".
    private func dailyChart(_ values: [Int]) -> some View {
        let peak = values.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tokens per day")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Chart(Array(values.enumerated()), id: \.offset) { day in
                BarMark(
                    x: .value("Day", day.offset),
                    y: .value("Tokens", day.element)
                )
                .foregroundStyle(day.offset == values.count - 1 ? Color.primary : Color.secondary)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 48)
            .transaction { $0.animation = nil }
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per day over \(values.count) days. Peak \(peak.formatted(.number.notation(.compactName))), today \((values.last ?? 0).formatted(.number.notation(.compactName))).")
    }

    private func stat(_ title: String, value: Int, systemImage: String) -> some View {
        LabeledContent {
            Text(value, format: .number.notation(.compactName))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote)
        }
    }

    private func modelRow(_ usage: WatchModelUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usage.name)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                Text(usage.cost, format: .currency(code: "USD"))
                    .monospacedDigit()
                Text("·")
                Text(usage.totalTokens, format: .number.notation(.compactName))
                    .monospacedDigit()
                Text("tokens")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        phase = usage == nil ? .loading : phase
        let loaded = await model.loadUsage(days: days)
        usage = loaded ?? usage
        phase = loaded == nil ? .after(model) : .loaded
    }
}
