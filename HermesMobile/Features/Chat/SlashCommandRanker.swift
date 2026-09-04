import Foundation

/// The searchable text of one autocomplete candidate.
///
/// `name` is what the user types (`model`, `claude-code`), `label` the
/// human-readable title when it differs from the name, and the two description
/// fields the supporting copy. Only `name` and `label` are matched fuzzily,
/// because a loose subsequence hit deep inside a sentence is noise.
struct SlashRankableFields: Sendable {
    var name: String
    var label: String?
    var shortDescription: String?
    var description: String?

    init(name: String, label: String? = nil, shortDescription: String? = nil, description: String? = nil) {
        self.name = name
        self.label = label
        self.shortDescription = shortDescription
        self.description = description
    }
}

/// Lower-is-better ranking for the slash-command popover.
///
/// Each field scores the query on how strongly it matched — exact, prefix, word
/// boundary, contains, or (names only) fuzzy subsequence — and a candidate keeps
/// its best, i.e. lowest, field score. Field bases are staggered so any name hit
/// beats any label hit, which beats any description hit. Callers pass their own
/// field mapping to `rank`, which returns the best `limit` candidates.
enum SlashCommandRanker {
    /// Upper bound on rendered rows, so a large skill catalog cannot flood the popover.
    static let resultLimit = 20

    /// Characters that start a new word inside a slug or a title.
    private static let boundaryMarkers: Set<Character> = ["-", "_", "/"]

    /// A field's score base plus its dedicated fuzzy score; `nil` fuzzy disables
    /// subsequence matching for that field.
    private struct FieldWeight {
        let base: Int
        let fuzzy: Int?
    }

    private static let nameWeight = FieldWeight(base: 0, fuzzy: 100)
    private static let labelWeight = FieldWeight(base: 1, fuzzy: 110)
    private static let shortDescriptionWeight = FieldWeight(base: 20, fuzzy: nil)
    private static let descriptionWeight = FieldWeight(base: 30, fuzzy: nil)

    /// The best score across every field, or `nil` when nothing matched.
    /// An empty query matches everything at the top score.
    static func score(_ fields: SlashRankableFields, matching query: String) -> Int? {
        score(fields, normalizedQuery: normalized(query))
    }

    /// Returns the best `limit` items for `query`, ordered by score, then label,
    /// then name. An empty query keeps the caller's own order untouched, so a
    /// curated command list still reads the way it was written.
    static func rank<Item>(
        _ items: [Item],
        matching query: String,
        limit: Int = resultLimit,
        fields: (Item) -> SlashRankableFields
    ) -> [Item] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return items }
        guard limit > 0 else { return [] }

        var ranked: [RankedItem<Item>] = []
        ranked.reserveCapacity(min(limit, items.count))

        for item in items {
            let itemFields = fields(item)
            guard let score = score(itemFields, normalizedQuery: needle) else { continue }

            let entry = RankedItem(
                item: item,
                score: score,
                label: normalized(itemFields.label ?? itemFields.name),
                name: normalized(itemFields.name)
            )

            if ranked.count == limit, !entry.sorts(before: ranked[limit - 1]) { continue }

            let insertionIndex = ranked.firstIndex { entry.sorts(before: $0) } ?? ranked.count
            ranked.insert(entry, at: insertionIndex)
            if ranked.count > limit { ranked.removeLast() }
        }

        return ranked.map(\.item)
    }

    // MARK: - Scoring

    private struct RankedItem<Item> {
        let item: Item
        let score: Int
        let label: String
        let name: String

        /// Strictly-before, so equally ranked candidates keep their input order.
        func sorts(before other: RankedItem<Item>) -> Bool {
            if score != other.score { return score < other.score }
            if label != other.label { return label < other.label }
            return name < other.name
        }
    }

    private static func score(_ fields: SlashRankableFields, normalizedQuery needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }

        let weighted: [(String?, FieldWeight)] = [
            (fields.name, nameWeight),
            (fields.label, labelWeight),
            (fields.shortDescription, shortDescriptionWeight),
            (fields.description, descriptionWeight)
        ]

        var best: Int?
        for (raw, weight) in weighted {
            guard let value = raw.map(normalized), !value.isEmpty else { continue }
            guard let fieldScore = score(field: value, needle: needle, weight: weight) else { continue }
            if best.map({ fieldScore < $0 }) ?? true { best = fieldScore }
        }
        return best
    }

    private static func score(field: String, needle: String, weight: FieldWeight) -> Int? {
        if field == needle { return weight.base }
        if field.hasPrefix(needle) { return weight.base + 2 }
        if hasBoundaryPrefix(field, needle) { return weight.base + 4 }
        if field.contains(needle) { return weight.base + 6 }
        guard let fuzzy = weight.fuzzy, isSubsequence(needle, of: field) else { return nil }
        return fuzzy
    }

    /// True when the needle starts a word inside the field, e.g. `code` in `claude-code`.
    private static func hasBoundaryPrefix(_ field: String, _ needle: String) -> Bool {
        var searchStart = field.startIndex
        while let marker = field[searchStart...].firstIndex(where: boundaryMarkers.contains) {
            let wordStart = field.index(after: marker)
            guard wordStart < field.endIndex else { return false }
            if field[wordStart...].hasPrefix(needle) { return true }
            searchStart = wordStart
        }
        return false
    }

    /// True when every needle character appears in the field, in order.
    private static func isSubsequence(_ needle: String, of field: String) -> Bool {
        var iterator = field.makeIterator()
        for character in needle {
            var matched = false
            while let next = iterator.next() {
                if next == character {
                    matched = true
                    break
                }
            }
            guard matched else { return false }
        }
        return true
    }

    /// Case folding is plain `lowercased()` on purpose: command names and skill
    /// slugs are ASCII, and locale-sensitive folding would make ranking depend
    /// on the device language.
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
