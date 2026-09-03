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

    private static let sampleGroups: [ModelCatalogGroup] = documentedProviders.map { provider in
        ModelCatalogGroup(
            id: provider.id,
            name: provider.id,
            providerID: provider.id,
            models: [
                ModelCatalogOption(id: "\(provider.id)-sample-1", displayName: "\(provider.name) Sample", providerID: provider.id),
                ModelCatalogOption(id: "\(provider.id)-sample-2", displayName: "\(provider.name) Sample Mini", providerID: provider.id),
            ]
        )
    }

    var body: some View {
        List {
            Section {
                Button("Open Model Picker with Every Provider") {
                    showsPicker = true
                }
            } footer: {
                Text("Same picker as the composer, fed a synthetic catalog with one group per documented provider ID.")
            }

            Section("Documented provider IDs") {
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
            }
        }
        .navigationTitle("Provider Glyphs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPicker) {
            ComposerModelPickerSheet(
                modelGroups: Self.sampleGroups,
                selectedModelID: "openai-codex-sample-1",
                selectedModelProviderID: "openai-codex",
                favoriteModelKeys: [],
                recentModelKeys: [],
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
