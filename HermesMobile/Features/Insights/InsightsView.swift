import SwiftUI

/// The Usage screen: a window picker, one hero figure with a chart under it, the
/// window totals, and the per-model breakdown. Every figure comes from
/// `GET /api/insights`, or from local session metadata when that call fails.
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
            .navigationTitle("Usage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadInsights() }
                    } label: {
                        // The spinner marks a re-fetch of something already on
                        // screen. A first load has its own placeholder, and a
                        // server that never answers must not pin it on here.
                        if viewModel.isRefreshing {
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
            ProgressView("Loading usage...")
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoadedAnalytics {
            ContentUnavailableView {
                Label("Could Not Load Usage", systemImage: "exclamationmark.triangle")
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
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Window", selection: $viewModel.selectedTimeframe) {
                    ForEach(AnalyticsTimeframe.allCases) { timeframe in
                        Text(timeframe.title).tag(timeframe)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.dataSource != .server {
                    UsageCard {
                        Label {
                            Text(viewModel.sourceDescription)
                                .font(AppFont.caption())
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                UsageChartCard(
                    buckets: viewModel.chartBuckets,
                    metric: $viewModel.metric,
                    showsMetricToggle: viewModel.showsMetricToggle,
                    windowTotal: viewModel.heroFigure,
                    hourlyNote: viewModel.hourlyChartNote,
                    chartAccessibilityLabel: viewModel.chartAccessibilityLabel
                )

                UsageTotalsGrid(cells: viewModel.totalsCells)

                if !viewModel.modelBreakdowns.isEmpty {
                    UsageModelsCard(
                        models: viewModel.modelBreakdowns,
                        hasCost: viewModel.estimatedCost > 0
                    )
                }

                if !viewModel.topSessions.isEmpty {
                    UsageTopSessionsCard(sessions: viewModel.topSessions)
                }

                Text(viewModel.sourceDescription)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await loadInsights()
        }
    }

    private func loadInsights() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}
