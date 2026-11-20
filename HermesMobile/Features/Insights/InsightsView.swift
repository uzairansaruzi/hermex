import SwiftUI

struct InsightsView: View {
    let onAPIError: (Error) -> Void
    private let profile: String?

    @State private var viewModel: InsightsViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.init(client: APIClient(baseURL: server), onAPIError: onAPIError)
    }

    init(client: any InsightsDataClient, profile: String? = nil, limitsScope: ProviderLimitsPublisher.Scope? = nil,
         onAPIError: @escaping (Error) -> Void) {
        self.onAPIError = onAPIError
        self.profile = profile
        _viewModel = State(initialValue: InsightsViewModel(client: client, publishesLimits: limitsScope))
    }

    var body: some View {
        content
            .modifier(UsageTitle(profile: profile))
            .onAppear { UsageReports.shared.record(.insights) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
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
            .task {
                await viewModel.loadLimits()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.hasLoadedAnalytics {
            loadedContent
        } else if viewModel.features.fallsBackToSessions {
            placeholder
        } else {
            VStack(spacing: 0) {
                windowPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                placeholder
                    .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if viewModel.isLoading {
            ProgressView("Loading usage...")
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView {
                Label("Could Not Load Usage", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadInsights() }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Data", systemImage: "chart.bar")
            } description: {
                Text("Session usage data will appear here once you have conversations.")
            }
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $viewModel.selectedTimeframe) {
            ForEach(viewModel.timeframes) { timeframe in
                Text(timeframe.title).tag(timeframe)
            }
        }
        .pickerStyle(.segmented)
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.showsLimits {
                    ProviderLimitsSection(
                        cards: viewModel.limitCards,
                        isLoading: viewModel.isLoadingLimits,
                        refreshFailed: !viewModel.staleLimitIDs.isEmpty
                    )
                }

                windowPicker

                if viewModel.dataSource != .server {
                    SectionCard {
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
                    showsChart: viewModel.loadedTimeframe.showsChart,
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
                    .foregroundStyle(.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await refresh()
        }
    }

    private func refresh() async {
        let limits = Task { await viewModel.loadLimits(refresh: true) }
        await loadInsights()
        await limits.value
    }

    private func loadInsights() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

private struct UsageTitle: ViewModifier {
    let profile: String?

    func body(content: Content) -> some View {
        if let profile {
            if #available(iOS 26, *) {
                content.themedPageBackground().navigationTitle("Usage").navigationSubtitle(profile)
            } else {
                content.themedPageBackground().navigationTitle(Text(verbatim: "\(String(localized: "Usage")) · \(profile)"))
            }
        } else {
            content.themedPageBackground().navigationTitle("Usage")
        }
    }
}
