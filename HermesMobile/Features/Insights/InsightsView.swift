import SwiftUI

struct InsightsView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: InsightsViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: InsightsViewModel(server: server))
    }

    var body: some View {
        content
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .navigationTitle("Usage Analytics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadInsights() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .task(id: viewModel.selectedTimeframe) {
                await loadInsights()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoadedAnalytics {
            ProgressView("Loading analytics...")
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoadedAnalytics {
            ContentUnavailableView {
                Label("Could Not Load Analytics", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadInsights() }
                }
            }
        } else if !viewModel.hasLoadedAnalytics {
            ContentUnavailableView {
                Label("No Data", systemImage: "chart.bar")
            } description: {
                Text("Session usage data will appear here once you have conversations.")
            }
        } else {
            List {
                Section {
                    Picker("Timeframe", selection: $viewModel.selectedTimeframe) {
                        ForEach(AnalyticsTimeframe.allCases) { timeframe in
                            Text(timeframe.title).tag(timeframe)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    AnalyticsCard(title: String(localized: "Sessions"), value: "\(viewModel.sessionCount)", icon: "bubble.left.and.bubble.right", color: .blue)
                    AnalyticsCard(title: String(localized: "Messages"), value: formatTokens(viewModel.totalMessages), icon: "text.bubble", color: .cyan)
                    AnalyticsCard(title: String(localized: "Input Tokens"), value: formatTokens(viewModel.totalInputTokens), icon: "arrow.down.circle", color: .green)
                    AnalyticsCard(title: String(localized: "Output Tokens"), value: formatTokens(viewModel.totalOutputTokens), icon: "arrow.up.circle", color: .orange)
                    AnalyticsCard(title: String(localized: "Total Tokens"), value: formatTokens(viewModel.totalTokens), icon: "sum", color: .purple)
                    AnalyticsCard(title: String(localized: "Estimated Cost"), value: viewModel.estimatedCost.formattedCost(collapsingZeroCents: true), icon: "dollarsign.circle", color: .indigo)

                    if let cacheHitPercent = viewModel.totalCacheHitPercent {
                        AnalyticsCard(title: String(localized: "Cache Hit Rate"), value: formatPercent(cacheHitPercent), icon: "bolt.circle", color: .teal)
                    }

                    if let cacheReadTokens = viewModel.totalCacheReadTokens {
                        AnalyticsCard(title: String(localized: "Cache Read Tokens"), value: formatTokens(cacheReadTokens), icon: "arrow.counterclockwise.circle", color: .mint)
                    }
                } header: {
                    Text(viewModel.periodTitle)
                        .textCase(.uppercase)
                }

                if !viewModel.modelBreakdowns.isEmpty {
                    Section("Models") {
                        ForEach(Array(viewModel.modelBreakdowns.prefix(10).enumerated()), id: \.offset) { _, model in
                            ModelBreakdownRow(model: model)
                        }
                    }
                }

                if !viewModel.recentDailyTokens.isEmpty {
                    Section("Recent Daily Tokens") {
                        ForEach(Array(viewModel.recentDailyTokens.enumerated()), id: \.offset) { _, day in
                            DailyTokenRow(day: day)
                        }
                    }
                }

                if viewModel.peakDay != nil || viewModel.peakHour != nil {
                    Section("Activity") {
                        if let peakDay = viewModel.peakDay {
                            ActivitySummaryRow(
                                icon: "calendar",
                                title: String(localized: "Peak Day"),
                                value: peakDay.day ?? String(localized: "Unknown"),
                                detail: String(localized: "\(peakDay.sessions ?? 0) sessions")
                            )
                        }

                        if let peakHour = viewModel.peakHour {
                            ActivitySummaryRow(
                                icon: "clock",
                                title: String(localized: "Peak Hour"),
                                value: formatHour(peakHour.hour),
                                detail: String(localized: "\(peakHour.sessions ?? 0) sessions")
                            )
                        }
                    }
                }

                if !viewModel.topSessions.isEmpty {
                    Section("Top Sessions") {
                        ForEach(viewModel.topSessions.prefix(10)) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title ?? String(localized: "Untitled Session"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)

                                HStack(spacing: 12) {
                                    let input = session.inputTokens ?? 0
                                    let output = session.outputTokens ?? 0
                                    let total = input + output

                                    Text("\(formatTokens(total)) tokens")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)

                                    if let cost = session.estimatedCost, cost > 0 {
                                        Text(cost.formattedCost())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    Text(viewModel.sourceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await loadInsights()
            }
        }
    }

    private func loadInsights() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func formatTokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatHour(_ value: Int?) -> String {
        guard let value else { return String(localized: "Unknown") }
        return "\(String(format: "%02d", value)):00"
    }

    private func formatPercent(_ value: Double) -> String {
        insightsFormattedPercent(value)
    }
}

private struct AnalyticsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
