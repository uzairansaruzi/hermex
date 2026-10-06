import SwiftUI

/// The Usage screen: a window picker, one hero figure with a chart under it, the
/// window totals, and the per-model breakdown. On a webui server every figure comes from
/// `GET /api/insights`, or from local session metadata when that call fails. On a Hermes host
/// (#1074) they are one Profile's analytics, which the title names (`HermesInsightsClient`).
struct InsightsView: View {
    let onAPIError: (Error) -> Void
    private let profile: String?

    @State private var viewModel: InsightsViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.init(client: APIClient(baseURL: server), onAPIError: onAPIError)
    }

    /// The usage `client` reads: on a Hermes host, `profile`'s.
    init(client: any InsightsDataClient, profile: String? = nil, onAPIError: @escaping (Error) -> Void) {
        self.onAPIError = onAPIError
        self.profile = profile
        _viewModel = State(initialValue: InsightsViewModel(client: client))
    }

    var body: some View {
        content
            .modifier(UsageTitle(profile: profile))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
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
            // A separate, unkeyed task on purpose: a cold account-limits probe
            // can take several seconds upstream and the chart must not wait on
            // it, and quota does not depend on the window. Keying it to the
            // window would restart the probe on every picker change, wasting
            // traffic and letting the restarted load supersede an in-flight
            // explicit refresh. This load never passes `refresh` — that belongs
            // to explicit gestures.
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
            // Without a sessions fallback (Hermes) a failed window replaces the figures, so the
            // picker stays above the placeholder, where it sits once loaded, to leave that window.
            VStack(spacing: 0) {
                windowPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                placeholder
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// What stands in for the figures before any have loaded: progress, the error, or no data.
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
                        isLoading: viewModel.isLoadingLimits
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
            await refresh()
        }
    }

    /// An explicit refresh gesture: the toolbar button and pull-to-refresh. Only
    /// these bypass the server's 45 s quota cache. Both calls are started before
    /// either is awaited so the slower one does not serialize behind the other.
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

/// Titles the Usage screen. On a Hermes host it also names the Profile the figures are for:
/// under the title on iOS 26, and after it before that.
private struct UsageTitle: ViewModifier {
    let profile: String?

    func body(content: Content) -> some View {
        if let profile {
            if #available(iOS 26, *) {
                content.navigationTitle("Usage").navigationSubtitle(profile)
            } else {
                content.navigationTitle(Text(verbatim: "\(String(localized: "Usage")) · \(profile)"))
            }
        } else {
            content.navigationTitle("Usage")
        }
    }
}
