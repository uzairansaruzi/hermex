import SwiftUI

/// Read-only provider status screen (#26): which providers the server knows
/// about, whether each has a credential (and where it came from), which one is
/// active, and each provider's model catalog. Deliberately carries no write
/// affordances — API-key set/delete stays a server-side operation.
struct ProvidersView: View {
    let server: URL

    @State private var viewModel: ProvidersViewModel
    @State private var expandedProviderIndices: Set<Int> = []

    init(server: URL) {
        self.server = server
        _viewModel = State(initialValue: ProvidersViewModel(server: server))
    }

    var body: some View {
        content
            .navigationTitle("Providers")
            .background(Color(.systemBackground))
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.isLoading && viewModel.providers.isEmpty {
                    ProvidersStatusRow(title: String(localized: "Loading providers…"), systemImage: "key.horizontal")
                        .padding(.horizontal, 24)
                } else if let errorMessage = viewModel.errorMessage, viewModel.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ProvidersStatusRow(title: String(localized: "Could not load providers"), systemImage: "exclamationmark.triangle")

                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        Button("Try Again") {
                            Task { await viewModel.load() }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 24)
                } else if viewModel.providers.isEmpty {
                    ProvidersStatusRow(title: String(localized: "No providers reported by this server."), systemImage: "key.horizontal")
                        .padding(.horizontal, 24)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(viewModel.providers.enumerated()), id: \.offset) { index, provider in
                            ProviderRow(
                                provider: provider,
                                isActive: viewModel.isActive(provider),
                                isExpanded: expandedProviderIndices.contains(index),
                                toggleExpanded: { toggleExpanded(index) }
                            )
                        }

                        Text("Provider keys are managed on the server. This screen is read-only.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 44)
        }
    }

    private func toggleExpanded(_ index: Int) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedProviderIndices.contains(index) {
                expandedProviderIndices.remove(index)
            } else {
                expandedProviderIndices.insert(index)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderSummary
    let isActive: Bool
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ProvidersViewModel.displayName(for: provider))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .foregroundStyle(.green)
                }

                Spacer(minLength: 0)

                if let badge = ProvidersViewModel.keySourceBadge(for: provider) {
                    // Technical token (env / OAuth / config) — deliberately not localized.
                    Text(verbatim: badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                }
            }

            keyStatusLine

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

            if let models = provider.models, !models.isEmpty {
                modelsDisclosure(models)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var keyStatusLine: some View {
        if let hasKey = provider.hasKey {
            HStack(spacing: 6) {
                Image(systemName: hasKey ? "checkmark.seal.fill" : "key.slash")
                    .font(.caption)
                    .foregroundStyle(hasKey ? Color.green : Color.secondary)
                    .accessibilityHidden(true)

                Text(hasKey ? "Key configured" : "No key")
                    .font(.footnote)
                    .foregroundStyle(hasKey ? Color.primary : Color.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelsDisclosure(_ models: [ProviderModel]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleExpanded) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)

                    Text("Models (\(ProvidersViewModel.modelCount(for: provider)))")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this provider's model list.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                        if let title = modelTitle(model) {
                            Text(verbatim: title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let info = ProvidersViewModel.truncatedModelInfo(for: provider) {
                        Text("Showing \(info.shown) of \(info.total) models")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func modelTitle(_ model: ProviderModel) -> String? {
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

private struct ProvidersStatusRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}
