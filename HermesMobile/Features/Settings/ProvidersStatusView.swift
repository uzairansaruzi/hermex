import SwiftUI

struct ProvidersStatusView: View {
    let server: URL

    @State private var isLoading = false
    @State private var providers: [ProviderSummary] = []
    @State private var activeProvider: String?
    @State private var errorMessage: String?
    @State private var expandedProviderIDs: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProvidersStatusCard(title: String(localized: "Providers")) {
                    providerListContent
                }

                ProvidersStatusCard(title: String(localized: "Read Only")) {
                    Label("API key management is not available here.", systemImage: "lock")
                        .font(.subheadline.weight(.medium))

                    Text("This screen only shows provider status reported by the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProviders()
        }
        .refreshable {
            await loadProviders()
        }
    }

    @ViewBuilder
    private var providerListContent: some View {
        if isLoading && providers.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading providers...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let errorMessage, providers.isEmpty {
            Label("Could Not Load Providers", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))

            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if providers.isEmpty {
            Label("No Providers", systemImage: "tray")
                .font(.subheadline.weight(.semibold))

            Text("The server did not report any configured providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                    providerRow(provider)

                    if index < providers.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                toggleExpanded(provider)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(provider.displayTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            if provider.isActive(activeProvider: activeProvider) {
                                ProviderStatusBadge(title: String(localized: "Active"), tint: .accentColor)
                            }
                        }

                        HStack(spacing: 6) {
                            ProviderStatusBadge(
                                title: provider.keyStatusText,
                                tint: provider.hasKey == true ? .green : .secondary
                            )

                            if let keySourceBadge = provider.keySourceBadge {
                                ProviderStatusBadge(title: keySourceBadge, tint: .secondary)
                            }
                        }

                        Text(provider.modelCountText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: isExpanded(provider) ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded(provider) ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityHint("Shows this provider's models.")

            if let authError = provider.authErrorText {
                Label(authError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded(provider) {
                providerModels(provider)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func providerModels(_ provider: ProviderSummary) -> some View {
        let models = provider.visibleModels
        if models.isEmpty {
            Text("No models reported for this provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.label ?? model.id ?? String(localized: "Model"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)

                        if let id = model.id, id != model.label {
                            Text(id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 2)
        }
    }

    private func loadProviders() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await APIClient(baseURL: server).providers()
            guard !Task.isCancelled else { return }
            activeProvider = response.activeProvider
            providers = response.providers ?? []
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }

        guard !Task.isCancelled else { return }
        isLoading = false
    }

    private func isExpanded(_ provider: ProviderSummary) -> Bool {
        guard let id = provider.providerID else { return false }
        return expandedProviderIDs.contains(id)
    }

    private func toggleExpanded(_ provider: ProviderSummary) {
        guard let id = provider.providerID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedProviderIDs.contains(id) {
                expandedProviderIDs.remove(id)
            } else {
                expandedProviderIDs.insert(id)
            }
        }
    }
}

private struct ProvidersStatusCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct ProviderStatusBadge: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
