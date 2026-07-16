import XCTest

/// Guards the App Localization effort (issues #290, #291, …): every translatable key in
/// `Localizable.xcstrings` must carry a non-empty value in **each shipped language**. This
/// catches a dropped/forgotten translation before it ships as a blank string in that
/// language's build.
///
/// The catalog is JSON on disk; we read the source file directly (located relative to
/// this test via `#filePath`) so the guard runs without bundling the catalog into the
/// test target. Keys explicitly marked `"shouldTranslate": false` (brand names,
/// format-only artifacts) are intentionally skipped.
///
/// When a new language is added to the catalog, add its code to `shippedLanguages` so the
/// guard covers it too.
final class LocalizationCatalogTests: XCTestCase {

    /// Non-English languages compiled into the app. Keep in sync with `knownRegions` in the
    /// project file and the languages present in `Localizable.xcstrings`.
    private static let shippedLanguages = ["de", "es", "fr", "it", "pl", "pt-BR", "nl", "tr", "ru", "ja", "zh-Hans", "ko", "ar", "he", "ur", "zh-Hant", "zh-HK"]

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HermesMobileTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
    }

    private func catalogURL() -> URL {
        // .../HermesMobileTests/LocalizationCatalogTests.swift
        //   -> repo root -> HermesMobile/Resources/Localizable.xcstrings
        resourceURL("HermesMobile/Resources/Localizable.xcstrings")
    }

    /// True iff the language entry holds a non-empty value — either a plain `stringUnit` or
    /// a `plural` variation where every category is filled.
    private func hasNonEmptyValue(_ localization: [String: Any]) -> Bool {
        if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
            return !value.isEmpty
        }
        if let plural = ((localization["variations"] as? [String: Any])?["plural"] as? [String: Any]), !plural.isEmpty {
            return plural.values.allSatisfy { cat in
                let value = ((cat as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                return !(value ?? "").isEmpty
            }
        }
        return false
    }

    func testShippedLanguageTranslationsHaveNoEmptyValues() throws {
        let url = catalogURL()
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Could not read String Catalog at \(url.path); skipping — the source tree is not present in this environment (e.g. on a physical device or a remote test runner). Runs on the simulator/CI where the checkout exists.")
        }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en", "Development language should remain English.")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 200, "Catalog is unexpectedly small — string extraction may have regressed.")

        for language in Self.shippedLanguages {
            var missing: [String] = []
            var translated = 0

            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any] else { continue }
                if entry["shouldTranslate"] as? Bool == false { continue }   // intentionally excluded

                guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else {
                    missing.append(key)
                    continue
                }
                hasNonEmptyValue(localization) ? (translated += 1) : missing.append(key)
            }

            XCTAssertTrue(missing.isEmpty,
                          "[\(language)] \(missing.count) translatable key(s) have no value: \(missing.sorted())")
            XCTAssertGreaterThan(translated, 200, "[\(language)] Far fewer translations than expected — something dropped.")
        }
    }

    func testAppShortcutPhrasesHaveDedicatedCatalogEntries() throws {
        let url = resourceURL("HermesMobile/Resources/AppShortcuts.xcstrings")
        let data = try Data(contentsOf: url)

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expectedPhrases = [
            "New chat in ${applicationName}",
            "New ${applicationName} chat",
            "Start a new chat in ${applicationName}",
            "New voice chat in ${applicationName}",
            "New ${applicationName} voice chat",
            "Start a voice chat in ${applicationName}",
            "New ${profile} chat in ${applicationName}",
            "Start a new ${profile} chat in ${applicationName}",
            "New chat in ${profile} on ${applicationName}"
        ]

        XCTAssertEqual(Set(strings.keys), Set(expectedPhrases))

        for phrase in expectedPhrases {
            let entry = try XCTUnwrap(strings[phrase] as? [String: Any], phrase)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], phrase)
            for language in Self.shippedLanguages + ["en"] {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any], "[\(language)] \(phrase)")
                XCTAssertTrue(hasNonEmptyValue(localization), "[\(language)] \(phrase) is empty")
            }
        }
    }

    func testKanbanCardDetailCopyIsLocalizedInEveryShippedLanguage() throws {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let detailKeys = [
            "Card ID", "Comment", "Comment cannot be blank.", "Created", "Dependencies",
            "Description", "Dispatch Runs", "Events", "Maximum Runtime", "Metadata",
            "Operational History", "Operational Metadata", "Outcome Uncertain", "Priority",
            "Run ID", "Updated", "Worker ID", "Worker Log",
            "This Board no longer exists. Return to Kanban to choose another Board.",
            "This Card no longer exists on this Board. The Board has been refreshed."
        ]

        for key in detailKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in Self.shippedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "[\(language)] \(key)"
                )
                XCTAssertTrue(hasNonEmptyValue(localization), "[\(language)] \(key) is empty")
            }
        }
    }
}
