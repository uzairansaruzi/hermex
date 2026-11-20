import Foundation

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

enum SlashCommandRanker {
    static let resultLimit = 20

    private static let boundaryMarkers: Set<Character> = ["-", "_", "/"]

    private struct FieldWeight {
        let base: Int
        let fuzzy: Int?
    }

    private static let nameWeight = FieldWeight(base: 0, fuzzy: 100)
    private static let labelWeight = FieldWeight(base: 1, fuzzy: 110)
    private static let shortDescriptionWeight = FieldWeight(base: 20, fuzzy: nil)
    private static let descriptionWeight = FieldWeight(base: 30, fuzzy: nil)

    static func score(_ fields: SlashRankableFields, matching query: String) -> Int? {
        score(fields, normalizedQuery: normalized(query))
    }

    static func rank<Item>(
        _ items: [Item],
        matching query: String,
        limit: Int = resultLimit,
        fields: (Item) -> SlashRankableFields
    ) -> [Item] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return items }
        guard limit > 0 else { return [] }

        var matches: [RankedItem<Item>] = []
        matches.reserveCapacity(items.count)

        for item in items {
            let itemFields = fields(item)
            guard let score = score(itemFields, normalizedQuery: needle) else { continue }

            matches.append(
                RankedItem(
                    item: item,
                    score: score,
                    label: normalized(itemFields.label ?? itemFields.name),
                    name: normalized(itemFields.name)
                )
            )
        }

        return matches
            .sorted { $0.sorts(before: $1) }
            .prefix(limit)
            .map(\.item)
    }

    private struct RankedItem<Item> {
        let item: Item
        let score: Int
        let label: String
        let name: String

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

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
