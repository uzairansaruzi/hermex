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
    private static let shippedLanguages = ["ca", "de", "es", "fr", "it", "pl", "pt-BR", "nl", "tr", "ru", "ja", "zh-Hans", "ko", "ar", "he", "ur", "zh-Hant", "zh-HK"]

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
        var foundValue = false
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String,
           !value.isEmpty {
            foundValue = true
        }
        if let plural = ((localization["variations"] as? [String: Any])?["plural"] as? [String: Any]), !plural.isEmpty {
            let complete = plural.values.allSatisfy { cat in
                let value = ((cat as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                return !(value ?? "").isEmpty
            }
            return foundValue || complete
        }
        if let substitutions = localization["substitutions"] as? [String: Any] {
            let complete = substitutions.values.allSatisfy { rawSubstitution in
                guard let substitution = rawSubstitution as? [String: Any],
                      let variations = substitution["variations"] as? [String: Any] else {
                    return false
                }
                return variations.values.allSatisfy { rawCases in
                    guard let cases = rawCases as? [String: Any], !cases.isEmpty else {
                        return false
                    }
                    return cases.values.allSatisfy { rawCase in
                        let value = (((rawCase as? [String: Any])?["stringUnit"] as? [String: Any])?["value"]) as? String
                        return !(value ?? "").isEmpty
                    }
                }
            }
            return foundValue && complete
        }
        return foundValue
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
        XCTAssertEqual(strings.count, 11)
        for phrase in strings.keys {
            let entry = try XCTUnwrap(strings[phrase] as? [String: Any], phrase)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], phrase)
            for language in Self.shippedLanguages + ["en"] {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any], "[\(language)] \(phrase)")
                XCTAssertTrue(hasNonEmptyValue(localization), "[\(language)] \(phrase) is empty")
            }
            XCTAssertTrue(phrase.contains("${applicationName}"), phrase)
        }
        XCTAssertEqual(strings.keys.filter { $0.contains("${profile}") }.count, 3)
    }

    /// #887: the notification service titles relay banners "<bot name> · <label>". Every
    /// translation keeps the one placeholder, or the banner would lose the bot's name.
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

    /// The hermex-push relay sends these keys as the `loc-key` of a Live Activity's end alert
    /// (#888), and iOS resolves them from this catalog. A rename or cleanup here has no
    /// compile error to catch it: the alert would silently fall back to the English key.
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

    func testCatalanPluralBranchesCoverEveryEnglishCase() throws {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            guard let entry = rawEntry as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any],
                  let catalan = localizations["ca"] as? [String: Any] else {
                continue
            }

            if let englishPlural = ((english["variations"] as? [String: Any])?["plural"] as? [String: Any]) {
                let catalanPlural = try XCTUnwrap(
                    (catalan["variations"] as? [String: Any])?["plural"] as? [String: Any],
                    "\(key) is missing Catalan plural variations"
                )
                XCTAssertEqual(Set(catalanPlural.keys), Set(englishPlural.keys), key)
                for (category, rawValue) in catalanPlural {
                    let value = ((rawValue as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                    XCTAssertFalse((value ?? "").isEmpty, "\(key) [\(category)] is empty")
                }
            }

            let englishSubstitutions = english["substitutions"] as? [String: Any] ?? [:]
            let catalanSubstitutions = catalan["substitutions"] as? [String: Any] ?? [:]
            XCTAssertEqual(Set(catalanSubstitutions.keys), Set(englishSubstitutions.keys), key)
            for (name, rawEnglish) in englishSubstitutions {
                let englishVariations = (rawEnglish as? [String: Any])?["variations"] as? [String: Any] ?? [:]
                let catalanVariations = (catalanSubstitutions[name] as? [String: Any])?["variations"] as? [String: Any] ?? [:]
                XCTAssertEqual(Set(catalanVariations.keys), Set(englishVariations.keys), "\(key) [\(name)]")
                for (kind, rawEnglishCases) in englishVariations {
                    let englishCases = rawEnglishCases as? [String: Any] ?? [:]
                    let catalanCases = catalanVariations[kind] as? [String: Any] ?? [:]
                    XCTAssertEqual(Set(catalanCases.keys), Set(englishCases.keys), "\(key) [\(name).\(kind)]")
                    for (category, rawCase) in catalanCases {
                        let value = ((rawCase as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                        XCTAssertFalse((value ?? "").isEmpty, "\(key) [\(name).\(kind).\(category)] is empty")
                    }
                }
            }
        }
    }

    func testCatalanAuxiliaryAndShareExtensionCatalogsAreComplete() throws {
        for path in [
            "HermesMobile/Resources/Auxiliary.xcstrings",
            "HermesShareExtension/Resources/ShareExtension.xcstrings"
        ] {
            let data = try Data(contentsOf: resourceURL(path))
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], path)
            XCTAssertEqual(root["sourceLanguage"] as? String, "en", path)
            let strings = try XCTUnwrap(root["strings"] as? [String: Any], path)
            XCTAssertFalse(strings.isEmpty, path)
            for (key, rawEntry) in strings {
                let localizations = try XCTUnwrap((rawEntry as? [String: Any])?["localizations"] as? [String: Any], "\(path) \(key)")
                for language in ["en", "ca"] {
                    let localization = try XCTUnwrap(localizations[language] as? [String: Any], "\(path) [\(language)] \(key)")
                    XCTAssertTrue(hasNonEmptyValue(localization), "\(path) [\(language)] \(key) is empty")
                }
            }
        }
    }

    func testCatalanInfoPlistStringsCoverEveryPermissionDescription() throws {
        let url = resourceURL("HermesMobile/Resources/ca.lproj/InfoPlist.strings")
        let values = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], url.path)
        let expected = Set([
            "NSLocalNetworkUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSCameraUsageDescription",
            "NSFaceIDUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
            "NSSpeechRecognitionUsageDescription"
        ])
        XCTAssertEqual(Set(values.keys), expected)
        XCTAssertTrue(values.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}
