import SwiftUI
import UIKit

enum ProviderGlyphKind: String, CaseIterable, Sendable {
    case actual
    case alibaba
    case anthropic
    case arcee
    case cloudflare
    case commandCode = "commandcode"
    case deepInfra = "deepinfra"
    case deepSeek = "deepseek"
    case fireworks
    case gmi
    case google
    case kiloCode = "kilocode"
    case lmStudio = "lmstudio"
    case meta
    case microsoft
    case miniMax = "minimax"
    case mistral
    case moonshot
    case nebius
    case nous
    case novita
    case nvidia
    case ollama
    case openAI = "openai"
    case openCode = "opencode"
    case openRouter = "openrouter"
    case ramp
    case stepFun = "stepfun"
    case upstage
    case xAI = "xai"
    case xiaomi
    case zhipu

    static func resolve(providerID: String?) -> ProviderGlyphKind? {
        guard let providerID else { return nil }
        let normalized = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)

        switch normalized {
        case "actual", "actualcomputer", "theactualcomputercompany":
            return .actual
        case "alibaba", "alibabacloud", "aliyun", "dashscope", "qwen":
            return .alibaba
        case "anthropic", "claude", "claudeagent", "claudecode":
            return .anthropic
        case "arcee", "arceeai":
            return .arcee
        case "cloudflare", "cloudflareai", "cloudflareaigateway", "aigateway", "cfgateway":
            return .cloudflare
        case "command", "commandcode":
            return .commandCode
        case "deepinfra":
            return .deepInfra
        case "deepseek":
            return .deepSeek
        case "fireworks", "fireworksai":
            return .fireworks
        case "gmi", "gmicloud":
            return .gmi
        case "google", "googleai", "googleaistudio", "googlegemini", "gemini", "vertex", "vertexai":
            return .google
        case "kilo", "kilocode":
            return .kiloCode
        case "lmstudio", "elementlabs":
            return .lmStudio
        case "meta", "metallama", "llama":
            return .meta
        case "microsoft", "azure", "azureopenai", "copilot", "github", "githubcopilot", "githubmodels":
            return .microsoft
        case "minimax", "minimaxcn", "minimaxchina":
            return .miniMax
        case "mistral", "mistralai":
            return .mistral
        case "moonshot", "moonshotai", "kimi", "kimicoding":
            return .moonshot
        case "nebius":
            return .nebius
        case "nous", "nousportal", "nousresearch":
            return .nous
        case "novita", "novitaai":
            return .novita
        case "nvidia", "nvidianim", "nim", "nemotron":
            return .nvidia
        case "ollama", "ollamacloud":
            return .ollama
        case "openai", "openaiapi", "openaicodex", "codex", "chatgpt":
            return .openAI
        case "opencode", "opencodego", "opencodezen", "opencodefree":
            return .openCode
        case "openrouter":
            return .openRouter
        case "ramp", "ramprouter", "router":
            return .ramp
        case "step", "stepfun":
            return .stepFun
        case "upstage":
            return .upstage
        case "xai", "grok", "xaioauth":
            return .xAI
        case "xiaomi", "xiaomimimo", "mimo":
            return .xiaomi
        case "zai", "glm", "zhipu", "zhipuai":
            return .zhipu
        default:
            return familyPrefixes.first { normalized.hasPrefix($0.prefix) }?.kind
        }
    }

    /// Upstream keeps adding suffixed variants of existing providers
    /// (`opencode-free`, `alibaba-coding-plan`, `kimi-coding-cn`, `qwen-oauth`).
    /// When no exact alias matches, a known family prefix inherits the family
    /// glyph so a new suffix never ships bare. Exact aliases always win.
    private static let familyPrefixes: [(prefix: String, kind: ProviderGlyphKind)] = [
        ("alibaba", .alibaba),
        ("qwen", .alibaba),
        ("anthropic", .anthropic),
        ("claude", .anthropic),
        ("azure", .microsoft),
        ("copilot", .microsoft),
        ("deepseek", .deepSeek),
        ("gemini", .google),
        ("google", .google),
        ("kimi", .moonshot),
        ("moonshot", .moonshot),
        ("minimax", .miniMax),
        ("mistral", .mistral),
        ("nebius", .nebius),
        ("nvidia", .nvidia),
        ("ollama", .ollama),
        ("openai", .openAI),
        ("opencode", .openCode),
        ("xai", .xAI),
    ]

    var isPrimaryCatalog: Bool {
        self == .anthropic || self == .openAI
    }

    /// These marks encode their shape with multiple colors or negative space;
    /// template rendering would collapse them into an unreadable solid tile.
    var usesOriginalColors: Bool {
        switch self {
        case .alibaba, .gmi, .lmStudio, .mistral, .moonshot, .nous, .nvidia, .stepFun, .xiaomi:
            return true
        default:
            return false
        }
    }
}

/// A bundled Logo.dev provider mark. Unknown/custom providers intentionally
/// render no placeholder so an unrecognized server value never looks branded.
struct ProviderGlyph: View {
    let providerID: String?

    @ViewBuilder
    var body: some View {
        if let kind = ProviderGlyphKind.resolve(providerID: providerID),
           let image = ProviderGlyphImageStore.image(for: kind) {
            Image(uiImage: image)
                .resizable()
                .renderingMode(kind.usesOriginalColors ? .original : .template)
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}

enum ProviderGlyphImageStore {
    static func image(for kind: ProviderGlyphKind) -> UIImage? {
        images[kind]
    }

    private static let images: [ProviderGlyphKind: UIImage] = {
        guard let bundle = Bundle.providerLogos else { return [:] }

        return Dictionary(uniqueKeysWithValues: ProviderGlyphKind.allCases.compactMap { kind in
            guard
                let url = bundle.url(forResource: kind.rawValue, withExtension: "png"),
                let image = UIImage(contentsOfFile: url.path)
            else {
                return nil
            }
            return (kind, image)
        })
    }()
}

private extension Bundle {
    static let providerLogos: Bundle? = {
        guard let url = Bundle.main.url(forResource: "ProviderLogos", withExtension: "bundle") else {
            return nil
        }
        return Bundle(url: url)
    }()
}
