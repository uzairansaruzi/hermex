import SwiftUI

/// Read-only provider status screen (#26): which providers the server knows
/// about, whether each has a credential (and where it came from), which one is
/// active, and each provider's model catalog. Deliberately carries no write
/// affordances — API-key set/delete stays a server-side operation.
///
/// Chrome matches the composer's model picker (#361): a plain `List` of
/// provider disclosures, each labelled with the bundled provider glyph, the
/// name, and the catalog count.
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
        List {
            if viewModel.providers.isEmpty {
                statusRow
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            } else {
                if let errorMessage = viewModel.errorMessage {
                    refreshFailureBanner(detail: errorMessage)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
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
                    .listRowSeparator(.hidden)
                }

                Text("Provider keys are managed on the server. This screen is read-only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 24, trailing: 16))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
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

    /// Loading, load-failure, and empty-catalog states. Rendered as a full-height
    /// list row rather than an overlay so pull-to-refresh keeps working.
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

    /// Shown above cached rows when a pull-to-refresh fails: the list would
    /// otherwise look freshly loaded even though the request errored (#42 review).
    private func refreshFailureBanner(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("Couldn't refresh. Showing previously loaded providers.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }

            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// Expansion is keyed by the provider's stable id so refreshes that reorder
    /// the list (the server sorts active-first) keep the right rows expanded;
    /// entries without an id fall back to their position.
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

/// One provider: a disclosure whose label carries the glyph, name, catalog
/// count, and credential state, and whose body lists the provider's models.
/// A provider the server sent no models for renders the label alone.
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
            .tint(Color(.secondaryLabel))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .textCase(.uppercase)

                if let count = ProvidersViewModel.modelCountLabel(for: provider) {
                    Text(verbatim: count)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(modelCountAccessibilityLabel)
                }

                Spacer(minLength: 0)
            }

            statusLine

            if let authError = ProvidersViewModel.authErrorText(for: provider) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    Text(authError)
                        .font(.footnote)
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

    /// Key status on the leading edge, the Active and key-source badges trailing.
    /// The badges keep their intrinsic width so the status text wraps first.
    @ViewBuilder
    private var statusLine: some View {
        let badge = ProvidersViewModel.keySourceBadge(for: provider)

        if provider.hasKey != nil || isActive || badge != nil {
            HStack(spacing: 6) {
                if let hasKey = provider.hasKey {
                    Image(systemName: hasKey ? "checkmark.seal.fill" : "key.slash")
                        .font(.caption)
                        .foregroundStyle(hasKey ? Color.green : Color.secondary)
                        .accessibilityHidden(true)

                    Text(hasKey ? "Key configured" : "No key")
                        .font(.footnote)
                        .foregroundStyle(hasKey ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .foregroundStyle(.green)
                        .layoutPriority(1)
                }

                if let badge {
                    // Technical token (env / OAuth / config) — deliberately not localized.
                    Text(verbatim: badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
        }
    }

    /// Model rows reuse the picker's row geometry so a provider's catalog reads
    /// the same on both screens. Entries without a label or id are skipped.
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
                        .font(.body)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
    }

    /// "Showing X of Y models" when the server trimmed the catalog, otherwise the
    /// plain count — the visible label is compact, so VoiceOver gets the words.
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
