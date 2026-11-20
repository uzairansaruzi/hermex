import XCTest

final class LocalizationCatalogTests: XCTestCase {

    private static let shippedLanguages = ["de", "es", "fr", "it", "pl", "pt-BR", "nl", "tr", "ru", "ja", "zh-Hans", "ko", "ar", "he", "ur", "zh-Hant", "zh-HK", "fa"]

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func catalogURL() -> URL {
        resourceURL("HermesMobile/Resources/Localizable.xcstrings")
    }

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
                if entry["shouldTranslate"] as? Bool == false { continue }

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
        XCTAssertFalse(strings.isEmpty)
        for phrase in strings.keys {
            let entry = try XCTUnwrap(strings[phrase] as? [String: Any], phrase)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], phrase)
            for language in Self.shippedLanguages + ["en"] {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any], "[\(language)] \(phrase)")
                XCTAssertTrue(hasNonEmptyValue(localization), "[\(language)] \(phrase) is empty")
            }
        }
    }

    func testPushBannerLabelsAreLocalizedInEveryShippedLanguage() throws {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        for key in ["%@ · Approval needed", "%@ · Question", "%@ · Turn failed"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in Self.shippedLanguages {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any], "[\(language)] \(key)")
                let value = try XCTUnwrap((localization["stringUnit"] as? [String: Any])?["value"] as? String,
                                          "[\(language)] \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, 2, "[\(language)] \(key): \(value)")
            }
        }
    }

    func testRelayLiveActivityAlertKeysAreLocalizedInEveryShippedLanguage() throws {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        for key in ["Response complete", "Response failed"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "\(key) is missing; the relay sends it as a loc-key")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in Self.shippedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "[\(language)] \(key)"
                )
                XCTAssertTrue(hasNonEmptyValue(localization), "[\(language)] \(key) is empty")
                let translatedValue = (localization["stringUnit"] as? [String: Any])?["value"] as? String
                XCTAssertNotEqual(translatedValue, key, "[\(language)] \(key) still uses English")
            }
        }
    }
}
