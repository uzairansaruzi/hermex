import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexCodeInput` and its supporting pure helpers (`HermexCodeInputNormalizer`,
/// `HermexCodeInputLayout`), none of which exist yet in `HermexTextInput.swift`. These tests
/// reference the future public/pure symbols directly, so this suite is expected to fail to compile
/// until Task 2 production adds `HermexCodeInput`, `HermexCodeInputNormalizer`, and
/// `HermexCodeInputLayout`. The `HermexCodeInput` source contracts below are read as a source
/// contract against the shared file itself, mirroring the pattern already used by
/// `HermexTextInputTests`.
final class HermexCodeInputTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    private func hermexTextInputSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexTextInput.swift")
    }

    /// Isolates the `HermexCodeInput` struct body from the rest of the shared file so source
    /// contracts about its internals (native `TextField` count, box `ForEach`, accessibility) don't
    /// accidentally match unrelated code elsewhere in `HermexTextInput.swift`.
    private func hermexCodeInputRegion() throws -> String {
        let src = try hermexTextInputSource()
        guard let structRange = src.range(of: "struct HermexCodeInput") else {
            XCTFail("expected `struct HermexCodeInput` in HermexTextInput.swift")
            return ""
        }
        let remainder = src[structRange.lowerBound...]
        guard let nextStructRange = remainder.range(
            of: #"\nstruct \w"#,
            options: .regularExpression,
            range: remainder.index(after: remainder.startIndex)..<remainder.endIndex
        ) else {
            return String(remainder)
        }
        return String(remainder[remainder.startIndex..<nextStructRange.lowerBound])
    }

    // MARK: - Pure normalizer contracts

    func testNormalizeStripsNonASCIIDigitsAndWhitespaceThenTruncatesToLength() {
        XCTAssertEqual(HermexCodeInputNormalizer.normalize("12 ٣a34-567", length: 6), "123456")
    }

    func testNormalizePassesThroughAnAlreadyValidFourDigitCode() {
        XCTAssertEqual(HermexCodeInputNormalizer.normalize("9876", length: 4), "9876")
    }

    func testNormalizeTruncatesExcessDigitsToAnEightDigitLength() {
        XCTAssertEqual(HermexCodeInputNormalizer.normalize("123456789", length: 8), "12345678")
    }

    // MARK: - Pure layout contracts

    func testLayoutSpacingForSixDigitsUsesS8() {
        XCTAssertEqual(HermexCodeInputLayout.spacing(for: 6), HermesSpacing.s8)
    }

    func testLayoutSpacingForEightDigitsUsesS4() {
        XCTAssertEqual(HermexCodeInputLayout.spacing(for: 8), HermesSpacing.s4)
    }

    func testLayoutSpacingForFourDigitsUsesS8() {
        XCTAssertEqual(HermexCodeInputLayout.spacing(for: 4), HermesSpacing.s8)
    }

    func testLayoutSpacingForSevenDigitsUsesS4() {
        XCTAssertEqual(HermexCodeInputLayout.spacing(for: 7), HermesSpacing.s4)
    }

    private func assertLayoutFits(length: Int, containerWidth: CGFloat) {
        let spacing = HermexCodeInputLayout.spacing(for: length)
        let boxWidth = HermexCodeInputLayout.boxWidth(containerWidth: containerWidth, length: length)
        let totalWidth = boxWidth * CGFloat(length) + spacing * CGFloat(length - 1)
        XCTAssertLessThanOrEqual(
            totalWidth, containerWidth + 0.001,
            "\(length)-box row at width \(containerWidth) must fit within the container"
        )
        XCTAssertLessThanOrEqual(boxWidth, 48, "box width must cap at 48pt")
    }

    func testLayoutBoxWidthFitsFourDigitsAtNarrowAndWideContainers() {
        assertLayoutFits(length: 4, containerWidth: 320)
        assertLayoutFits(length: 4, containerWidth: 390)
    }

    func testLayoutBoxWidthFitsSixDigitsAtNarrowAndWideContainers() {
        assertLayoutFits(length: 6, containerWidth: 320)
        assertLayoutFits(length: 6, containerWidth: 390)
    }

    func testLayoutBoxWidthFitsEightDigitsAtNarrowAndWideContainers() {
        assertLayoutFits(length: 8, containerWidth: 320)
        assertLayoutFits(length: 8, containerWidth: 390)
    }

    // MARK: - Compile contracts

    @MainActor
    func testHermexCodeInputCompilesWithTheDefaultSixDigitLength() {
        struct Host: View {
            @State var code = ""
            var body: some View {
                HermexCodeInput("Verification code", code: $code)
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testHermexCodeInputCompilesWithAnExplicitFourDigitLength() {
        struct Host: View {
            @State var code = ""
            var body: some View {
                HermexCodeInput("PIN", code: $code, length: 4)
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testHermexCodeInputCompilesWithAnExplicitEightDigitLength() {
        struct Host: View {
            @State var code = ""
            var body: some View {
                HermexCodeInput("Recovery code", code: $code, length: 8)
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testHermexCodeInputCompilesWithHelperErrorAndDisabledArguments() {
        struct Host: View {
            @State var code = ""
            var body: some View {
                HermexCodeInput(
                    "Verification code",
                    code: $code,
                    length: 6,
                    helperText: Text("Sent by SMS"),
                    errorText: Text("Incorrect code"),
                    isEnabled: false
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Source contracts: one native TextField as the editing/accessibility authority

    func testHermexCodeInputContainsExactlyOneNativeTextField() throws {
        let region = try hermexCodeInputRegion()
        let matches = region.components(separatedBy: "TextField(").count - 1
        XCTAssertEqual(matches, 1, "expected exactly one native TextField within HermexCodeInput")
    }

    func testHermexCodeInputUsesNumberPadKeyboard() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(region.contains(".keyboardType(.numberPad)"))
    }

    func testHermexCodeInputUsesOneTimeCodeContentType() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(region.contains(".textContentType(.oneTimeCode)"))
    }

    // MARK: - Source contracts: one row of accessibility-hidden visual boxes

    func testHermexCodeInputRendersOneRowOfBoxesViaForEachOverTheLength() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertNotNil(
            region.range(of: #"ForEach\(0\s*\.\.<\s*length"#, options: .regularExpression),
            "expected a single ForEach(0..<length ...) driving the visual boxes"
        )
    }

    func testHermexCodeInputHidesTheVisualBoxesFromAccessibility() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(
            region.contains("accessibilityHidden(true)"),
            "expected the visual box row to be hidden from accessibility"
        )
    }

    // MARK: - Source/localization contracts: accessibility value copy must not bypass the catalog
    //
    // `accessibilityValue` builds its progress copy ("No digits entered. 0 of 6." / "123456. 6 of 6
    // digits entered.") as a plain `String` and the call site wraps it in `Text(verbatim:)` — the
    // documented, legitimate escape hatch for copy that should never reach the catalog (identifiers,
    // paths, DEBUG-only text). Using it here for real spoken progress copy means
    // `ci/check_string_catalog.py` treats it as deliberately excluded rather than missing, so this
    // user-facing string stays permanently un-translatable with no red build to catch it.

    func testHermexCodeInputAccessibilityValueDoesNotHideUserFacingCopyBehindTextVerbatim() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertFalse(
            region.contains("Text(verbatim: accessibilityValue)"),
            "the code input's spoken digit-progress copy is real user-facing text, not an identifier or " +
                "debug string — Text(verbatim:) tells ci/check_string_catalog.py to ignore it, which is wrong here"
        )
    }

    func testHermexCodeInputAccessibilityValueStringsAreLocalized() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(
            region.contains("String(localized:"),
            "expected the code input's accessibilityValue copy to be built with String(localized:) so " +
                "ci/check_string_catalog.py's compiler-extraction scan can see it, instead of a plain String " +
                "literal wrapped in Text(verbatim:)"
        )
    }

    func testHermexCodeInputGroupsNativeFieldAccessibilitySemantics() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(region.contains("accessibilityLabel("), "expected a native accessibility label")
        XCTAssertTrue(region.contains("accessibilityValue("), "expected a native accessibility value")
        XCTAssertTrue(
            region.contains("accessibilityHint(") || region.contains("accessibilityElement(children: .combine)"),
            "expected native accessibility hint or a combined accessibility element grouping label/value/hint/error"
        )
    }

    // MARK: - Source contracts: shared border roles, fail-fast length, disabled focus resignation

    func testHermexCodeInputConsumesSharedSurfaceBorderRoles() throws {
        let region = try hermexCodeInputRegion()
        let source = try hermexTextInputSource()
        XCTAssertTrue(
            region.contains("HermexSurfaceBorderColors.resting") || source.contains("HermexSurfaceBorderColors.resting"),
            "expected HermexCodeInput (directly or via a shared field shell) to consume HermexSurfaceBorderColors.resting"
        )
    }

    func testHermexCodeInputGuardsLengthWithAFailFastProgrammerContract() throws {
        let region = try hermexCodeInputRegion()
        let hasPrecondition = region.range(
            of: #"precondition\(\s*\(4\.\.\.8\)\.contains\(length\)"#,
            options: .regularExpression
        ) != nil
        let hasAssert = region.range(
            of: #"assert\(\s*\(4\.\.\.8\)\.contains\(length\)"#,
            options: .regularExpression
        ) != nil
        XCTAssertTrue(
            hasPrecondition || hasAssert,
            "expected a precondition/assert fail-fast guard that length falls within 4...8"
        )
    }

    // MARK: - Source contracts: box height grows with Dynamic Type, 48pt default baseline (#974 review)

    func testHermexCodeInputScalesBoxHeightWithDynamicTypeRelativeToTitle3() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertNotNil(
            region.range(
                of: #"@ScaledMetric\(relativeTo:\s*\.title3\)[\s\S]{0,80}?=\s*HermexTextInputMetrics\.codeBoxHeight"#,
                options: .regularExpression
            ),
            "expected a @ScaledMetric relative to .title3, defaulting to the existing 48pt codeBoxHeight baseline, " +
                "so accessibility text sizes can grow the box without a fixed-height frame clipping it"
        )
    }

    func testHermexCodeInputNoLongerUsesTheUnscaledHeightConstantForTheBoxesOrRow() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertFalse(
            region.contains(".frame(height: HermexTextInputMetrics.codeBoxHeight)"),
            "expected the unscaled 48pt height constant to be replaced by the Dynamic-Type-aware scaled metric"
        )
    }

    func testHermexCodeInputUsesTheScaledHeightForBothTheRowAndEachBox() throws {
        let region = try hermexCodeInputRegion()
        let scaledHeightOccurrences = matches(of: #"\.frame\([^)]*height:\s*scaledCodeBoxHeight"#, in: region)
        XCTAssertEqual(
            scaledHeightOccurrences, 2,
            "expected the Dynamic-Type-scaled height on both the containing GeometryReader and each digit box, " +
                "so the greedy GeometryReader remains bounded while the 48pt baseline grows with the title3 text"
        )
    }

    func testHermexCodeInputBoxWidthFramingIsUnaffectedByTheHeightChange() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertTrue(
            region.contains(".frame(width: width, height: scaledCodeBoxHeight)"),
            "expected the per-box width framing to be preserved exactly, with only height made Dynamic-Type-aware"
        )
    }

    private func matches(of pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) } ?? 0
    }

    // MARK: - Source contracts: forbidden behavior

    func testHermexCodeInputDoesNotAutoSubmitOrExposeAnOnCompleteCallback() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertFalse(region.contains("onComplete"), "must not add an onComplete callback")
        XCTAssertFalse(region.contains("onSubmit("), "must not auto-submit")
    }

    func testHermexCodeInputDoesNotIntroduceASuccessColorState() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertFalse(region.contains("success"), "must not introduce a success color state")
    }

    func testHermexCodeInputDoesNotWrapASecureFieldOrMaskDigits() throws {
        let region = try hermexCodeInputRegion()
        XCTAssertFalse(region.contains("SecureField("), "must not behave like a masked PIN field")
    }

    func testHermexCodeInputDoesNotUseAPerBoxArrayOfTextEditors() throws {
        let region = try hermexCodeInputRegion()
        let textFieldCount = region.components(separatedBy: "TextField(").count - 1
        XCTAssertEqual(textFieldCount, 1, "must not create a per-box array of text editors")
        XCTAssertFalse(region.contains("[FocusState"), "must not create a per-box array of focus states")
    }
}
