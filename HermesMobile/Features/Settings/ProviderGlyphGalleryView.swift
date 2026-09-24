#if DEBUG
import SwiftUI

/// Debug-only gallery of every provider ID the Hermes docs list
/// (https://hermes-agent.nousresearch.com/docs/integrations/providers), so the
/// glyph mapping can be checked against the real model picker without having
/// each provider configured on a server. Not localized.
struct ProviderGlyphGalleryView: View {
    @State private var showsPicker = false

    /// Provider IDs as the docs spell them, with their display names.
    private static let documentedProviders: [(id: String, name: String)] = [
        ("nous", "Nous Portal"),
        ("openai-codex", "OpenAI Codex"),
        ("copilot", "GitHub Copilot"),
        ("copilot-acp", "GitHub Copilot ACP"),
        ("anthropic", "Anthropic"),
        ("openrouter", "OpenRouter"),
        ("router", "Ramp Router"),
        ("fireworks", "Fireworks AI"),
        ("novita", "NovitaAI"),
        ("ai-gateway", "AI Gateway"),
        ("zai", "z.ai / GLM"),
        ("kimi-coding", "Kimi / Moonshot"),
        ("kimi-coding-cn", "Kimi / Moonshot (China)"),
        ("arcee", "Arcee AI"),
        ("gmi", "GMI Cloud"),
        ("nebius-token-factory", "Nebius Token Factory"),
        ("actual", "Actual Computer"),
        ("minimax", "MiniMax"),
        ("minimax-cn", "MiniMax China"),
        ("minimax-oauth", "MiniMax OAuth"),
        ("xai", "xAI (Grok)"),
        ("xai-oauth", "xAI Grok OAuth"),
        ("alibaba", "Qwen Cloud (Alibaba DashScope)"),
        ("alibaba-coding-plan", "Alibaba Cloud (Coding Plan)"),
        ("alibaba-token-plan", "Alibaba Cloud (Token Plan)"),
        ("qwen-oauth", "Qwen OAuth"),
        ("kilocode", "Kilo Code"),
        ("xiaomi", "Xiaomi MiMo"),
        ("tencent-tokenhub", "Tencent TokenHub"),
        ("tencent-tokenplan", "Tencent TokenPlan"),
        ("opencode-zen", "OpenCode Zen"),
        ("opencode-go", "OpenCode Go"),
        ("opencode-free", "OpenCode Free"),
        ("commandcode", "CommandCode"),
        ("deepseek", "DeepSeek"),
        ("huggingface", "Hugging Face"),
        ("gemini", "Google / Gemini"),
        ("vertex", "Google Vertex AI"),
        ("openai-api", "OpenAI API"),
        ("azure-foundry", "Azure AI Foundry"),
        ("bedrock", "AWS Bedrock"),
        ("nvidia", "NVIDIA NIM"),
        ("ollama-cloud", "Ollama Cloud"),
        ("stepfun", "StepFun"),
        ("lmstudio", "LM Studio"),
        ("mistral", "Mistral"),
        ("custom", "Custom Endpoint"),
    ]

    /// Two sample models per provider, except OpenRouter, which gets the size
    /// the server really returns for it: 15 visible models and a 385-model
    /// `extra_models` tail, so "Show all models" and search can be checked
    /// against a large catalog.
    private static let sampleGroups: [ModelCatalogGroup] = documentedProviders.map { provider in
        let samples = [
            ModelCatalogOption(id: "\(provider.id)-sample-1", displayName: "\(provider.name) Sample", providerID: provider.id),
            ModelCatalogOption(id: "\(provider.id)-sample-2", displayName: "\(provider.name) Sample Mini", providerID: provider.id),
        ]
        guard provider.id == "openrouter" else {
            return ModelCatalogGroup(id: provider.id, name: provider.id, providerID: provider.id, models: samples)
        }

        let tail = (3...400).map { index in
            ModelCatalogOption(id: "openrouter-sample-\(index)", displayName: "OpenRouter Sample \(index)", providerID: provider.id)
        }
        return ModelCatalogGroup(
            id: provider.id,
            name: provider.id,
            providerID: provider.id,
            models: samples + tail.prefix(13),
            extraModels: Array(tail.dropFirst(13))
        )
    }

    var body: some View {
        List {
            Section {
                Button {
                    showsPicker = true
                } label: {
                    Text(verbatim: "Open Model Picker with Every Provider")
                }
            } footer: {
                Text(verbatim: "Same picker as the composer, fed a synthetic catalog with one group per documented provider ID. OpenRouter carries 400 models to exercise Show all models.")
            }

            Section {
                ForEach(Self.documentedProviders, id: \.id) { provider in
                    HStack(spacing: 12) {
                        ZStack {
                            if ProviderGlyphKind.resolve(providerID: provider.id) != nil {
                                ProviderGlyph(providerID: provider.id)
                            } else {
                                Image(systemName: "questionmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 17, height: 17)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: provider.id)
                                .font(.system(size: 14, weight: .semibold))
                                .textCase(.uppercase)
                            Text(verbatim: provider.name)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Text(verbatim: ProviderGlyphKind.resolve(providerID: provider.id)?.rawValue ?? "no glyph")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text(verbatim: "Documented provider IDs")
            }
        }
        .navigationTitle(Text(verbatim: "Provider Glyphs"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPicker) {
            ModelPickerSheet(
                configuration: .composer,
                modelGroups: Self.sampleGroups,
                selectedModelID: "openai-codex-sample-1",
                selectedModelProviderID: "openai-codex",
                favoriteModelKeys: [],
                recentModelKeys: [],
                isSelected: { option in
                    option.matchesSelection(
                        modelID: "openai-codex-sample-1",
                        providerID: "openai-codex"
                    )
                },
                onSelect: { _ in },
                onToggleFavorite: { _ in },
                onDeleteSavedCustom: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
#endif
