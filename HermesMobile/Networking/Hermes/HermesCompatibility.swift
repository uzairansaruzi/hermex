import Foundation

enum HermesCompatibility {
    static let minimumVersion = "0.21.3"
    static let testedVersion = "0.23.1"
    static let titlePreviewVersion = "0.21.6"
    static let titlePreviewLimit = 1_000

    static func supportsTitlePreview(_ version: String?) -> Bool {
        guard let reported = release(version), let minimum = release(titlePreviewVersion) else { return false }
        return !reported.lexicographicallyPrecedes(minimum)
    }

    static func boundedTitlePreview(_ text: String) -> String? {
        var units = 0
        let end = text.firstIndex { character in
            units += character.utf16.count
            return units > titlePreviewLimit
        } ?? text.endIndex
        return end == text.startIndex ? nil : String(text[..<end])
    }

    static func isSupported(_ version: String?) -> Bool {
        guard let reported = release(version), let minimum = release(minimumVersion) else { return true }
        return !reported.lexicographicallyPrecedes(minimum)
    }

    static func release(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let numbers = version.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }.split(separator: ".").compactMap { Int($0) }
        return numbers.count >= 3 ? Array(numbers.prefix(3)) : nil
    }
}
