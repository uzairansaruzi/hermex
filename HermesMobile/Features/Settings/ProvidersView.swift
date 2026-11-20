import SwiftUI

struct ProvidersView: View {
    let server: URL

    @State private var viewModel: ProvidersViewModel
    @State private var expandedProviderKeys: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(server: URL) {
        self.server = server
        _viewModel = State(initialValue: ProvidersViewModel(server: server))
    }

    var body: some View {
        AppList(rows: .plain) {
            if viewModel.providers.isEmpty {
                statusRow
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical)
                    .listRowInsets(EdgeInsets())
            } else {
                if let errorMessage = viewModel.errorMessage {
                    refreshFailureBanner(detail: errorMessage)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }

                ForEach(Array(viewModel.providers.enumerated()), id: \.offset) { index, provider in
                    let key = Self.expansionKey(for: provider, at: index)
                    ProviderDisclosure(
                        provider: provider,
                        isActive: viewModel.isActive(provider),
                        isExpanded: Binding(
                            get: { expandedProviderKeys.contains(key) },
                            set: { setExpanded($0, forKey: key) }
                        )
                    )
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }

                Text("Provider keys are managed on the server. This screen is read-only.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 24, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.appCanvas))
        .themedPageBackground()
        .navigationTitle("Providers")
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if viewModel.isLoading {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading providers…")
            }
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView {
                Label("Could not load providers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await viewModel.load() }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No providers reported by this server.", systemImage: "key.horizontal")
            }
        }
    }

    private func refreshFailureBanner(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppFont.caption())
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("Couldn't refresh. Showing previously loaded providers.")
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(.appPrimary)
                    .multilineTextAlignment(.leading)
            }

            Text(verbatim: detail)
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
    }

    static func expansionKey(for provider: ProviderSummary, at index: Int) -> String {
        if let id = provider.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }

        return "#\(index)"
    }

    private func setExpanded(_ isExpanded: Bool, forKey key: String) {
        if isExpanded {
            expandedProviderKeys.insert(key)
        } else {
            expandedProviderKeys.remove(key)
        }
    }
}

private struct ProviderDisclosure: View {
    let provider: ProviderSummary
    let isActive: Bool
    @Binding var isExpanded: Bool

    @ViewBuilder
    var body: some View {
        if let models = provider.models, !models.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                modelList(models)
            } label: {
                header
            }
            .tint(Color(.appTextSecondary))
            .accessibilityHint("Shows this provider's model list.")
        } else {
            header
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if ProviderGlyphKind.resolve(providerID: provider.id) != nil {
                    ProviderGlyph(providerID: provider.id)
                        .frame(width: 17, height: 17)
                }

                Text(ProvidersViewModel.displayName(for: provider))
                    .font(AppFont.fixed(size: 14, weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(1)
                    .textCase(.uppercase)

                if let count = ProvidersViewModel.modelCountLabel(for: provider) {
                    Text(verbatim: count)
                        .font(AppFont.fixed(size: 12, weight: .medium))
                        .foregroundStyle(.appSecondary)
                        .accessibilityLabel(modelCountAccessibilityLabel)
                }

                Spacer(minLength: 0)
            }

            statusLine

            if let authError = ProvidersViewModel.authErrorText(for: provider) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    Text(authError)
                        .font(AppFont.footnote())
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Authentication error: \(authError)"))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        let badge = ProvidersViewModel.keySourceBadge(for: provider)

        if provider.hasKey != nil || isActive || badge != nil {
            HStack(spacing: 6) {
                if let hasKey = provider.hasKey {
                    Image(systemName: hasKey ? "checkmark.seal.fill" : "key.slash")
                        .font(AppFont.caption())
                        .foregroundStyle(hasKey ? Color.green : Color(.appTextSecondary))
                        .accessibilityHidden(true)

                    Text(hasKey ? "Key configured" : "No key")
                        .font(AppFont.footnote())
                        .foregroundStyle(hasKey ? Color(.appText) : Color(.appTextSecondary))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if isActive {
                    Text("Active")
                        .font(AppFont.caption2(weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .foregroundStyle(.green)
                        .layoutPriority(1)
                }

                if let badge {
                    Text(verbatim: badge)
                        .font(AppFont.caption2(weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.appFillTertiary)))
                        .foregroundStyle(.appSecondary)
                        .layoutPriority(1)
                }
            }
        }
    }

    private func modelList(_ models: [ProviderModel]) -> some View {
        let titles = models.enumerated().compactMap { index, model in
            Self.modelTitle(model).map { (index: index, title: $0) }
        }

        return VStack(spacing: 1) {
            Divider()
                .padding(.leading, 10)

            LazyVStack(spacing: 1) {
                ForEach(titles, id: \.index) { entry in
                    Text(verbatim: entry.title)
                        .font(AppFont.body())
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
    }

    private var modelCountAccessibilityLabel: Text {
        if let info = ProvidersViewModel.truncatedModelInfo(for: provider) {
            return Text("Showing \(info.shown) of \(info.total) models")
        }

        return Text("Models (\(ProvidersViewModel.modelCount(for: provider)))")
    }

    private static func modelTitle(_ model: ProviderModel) -> String? {
        let label = model.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty {
            return label
        }

        let id = model.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            return id
        }

        return nil
    }
}
