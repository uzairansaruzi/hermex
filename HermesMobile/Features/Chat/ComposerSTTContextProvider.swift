import Foundation

/// Extracts contextual hot words from session data to improve STT accuracy.
/// These are injected into `SFSpeechAudioBufferRecognitionRequest.contextualStrings` (iOS 17+).
enum ComposerSTTContextProvider {

    /// Maximum number of hot words to inject (Apple recommends keeping this bounded).
    private static let maxHotWords = 50

    /// Regex patterns for extracting likely technical terms from messages.
    private static let technicalTermPatterns: [NSRegularExpression] = {
        let patterns = [
            // camelCase words (e.g. hermesMobile, setState)
            "[a-z]+[A-Z][a-zA-Z]*",
            // snake_case words (e.g. state_sync, sync_session_title)
            "[a-z]+_[a-z_]+",
            // dotted names (e.g. state.db, api.streaming)
            "[a-zA-Z][a-zA-Z0-9]*\\.[a-zA-Z][a-zA-Z0-9.]*",
            // ALL_CAPS identifiers (e.g. HERMES_HOME, TTS)
            "[A-Z][A-Z0-9_]{2,}",
            // slash-prefixed commands (e.g. /skills, /workspace)
            "/[a-zA-Z][a-zA-Z0-9_-]+",
            // kebab-case with 2+ segments (e.g. hermes-webui, speech-to-speech)
            "[a-z]+-[a-z]+(?:-[a-z]+)*",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Built-in terms relevant to the Hermes ecosystem.
    static let builtInTerms: [String] = [
        "Hermes", "Hermex", "hermes-webui", "hermes-agent",
        "state.db", "streaming", "session", "sessions",
        "composer", "barge-in", "voice mode",
        "skill", "skills", "memory", "cron",
        "provider", "model", "workspace", "profile",
    ]

    /// Build the hot-word list from session context + user-configured words.
    /// - Parameters:
    ///   - recentMessages: Recent message texts from the current session.
    ///   - sessionTitle: The current session title (if any).
    ///   - userHotWords: User-configured hot words from Settings.
    /// - Returns: Deduplicated array of contextual strings for STT boosting.
    static func hotWords(
        recentMessages: [String] = [],
        sessionTitle: String? = nil,
        userHotWords: String = ""
    ) -> [String] {
        var words = Set<String>(builtInTerms)

        // Add session title words.
        if let title = sessionTitle, !title.isEmpty {
            let titleWords = title.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count >= 3 }
            words.formUnion(titleWords)
        }

        // Extract technical terms from recent messages.
        for message in recentMessages.suffix(5) {
            let extracted = extractTechnicalTerms(from: message)
            words.formUnion(extracted)
        }

        // Add user-configured hot words.
        let userWords = userHotWords
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        words.formUnion(userWords)

        // Deduplicate case-insensitively, keeping the first-seen casing.
        var seen = Set<String>()
        var result: [String] = []
        for word in words.sorted() {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                result.append(word)
            }
        }

        return Array(result.prefix(maxHotWords))
    }

    /// Extract likely technical/project-specific terms from a text string.
    static func extractTechnicalTerms(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var terms: [String] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        for regex in technicalTermPatterns {
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                let term = nsText.substring(with: match.range)
                // Filter out very short matches and common words.
                if term.count >= 3, !commonWords.contains(term.lowercased()) {
                    terms.append(term)
                }
            }
        }

        return terms
    }

    /// Common English words to exclude from hot-word extraction.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all",
        "can", "had", "her", "was", "one", "our", "out", "has",
        "have", "from", "that", "this", "with", "they", "been",
        "will", "would", "could", "should", "their", "there",
        "when", "what", "which", "where", "about", "into",
    ]
}
