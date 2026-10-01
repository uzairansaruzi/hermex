import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the Hermex-owned Default and Password Text Input components
/// (`HermexTextInput.swift`): `HermexTextField` and `HermexSecureField` each keep a native
/// `TextField`/`SecureField` editor but own canonical Hermex presentation — a persistent visible
/// label, optional prompt, optional helper text, optional caller-owned error text that replaces
/// helper text, an `isEnabled` toggle with local focus resignation, and shared resting/focused/
/// Increased Contrast borders at Hermex field radius/spacing/minimum height. `HermexNumberField` is
/// removed. A SwiftUI view tree isn't inspectable at runtime without a rendering harness, so this is
/// a compile contract plus a source contract that pins the native forwarding, the canonical chrome,
/// and the absence of validation logic, error auto-clear, password reveal, a multiline wrapper, a
/// typed Number Field, and an enum-driven mega component.
final class HermexTextInputTests: XCTestCase {
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

    // MARK: - Compile contracts

    @MainActor
    func testHermexTextFieldCompilesWithALabelAndATextBinding() {
        struct Host: View {
            @State var value = ""
            var body: some View {
                HermexTextField("Name", text: $value)
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testHermexSecureFieldCompilesWithALabelAndATextBinding() {
        struct Host: View {
            @State var value = ""
            var body: some View {
                HermexSecureField("Password", text: $value)
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testBothFieldsCompileWithPromptHelperErrorAndDisabledArguments() {
        struct Host: View {
            @State var text = ""
            @State var secret = ""

            var body: some View {
                VStack {
                    HermexTextField(
                        "Name",
                        text: $text,
                        prompt: Text("Enter a name"),
                        helperText: Text("As it appears on your ID"),
                        errorText: Text("Name is required"),
                        isEnabled: false
                    )
                    HermexSecureField(
                        "Password",
                        text: $secret,
                        prompt: Text("Enter a password"),
                        helperText: Text("At least 8 characters"),
                        errorText: Text("Password is too short"),
                        isEnabled: false
                    )
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testBothFieldsDefaultToEnabledWhenIsEnabledIsOmitted() {
        struct Host: View {
            @State var text = ""
            @State var secret = ""
            var body: some View {
                VStack {
                    HermexTextField("Name", text: $text)
                    HermexSecureField("Password", text: $secret)
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Source contracts: native editors remain the editing authority

    func testHermexTextFieldWrapsANativeTextField() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("struct HermexTextField"))
        XCTAssertTrue(src.contains("TextField("), "expected HermexTextField to keep a native TextField editor")
    }

    func testHermexSecureFieldWrapsANativeSecureField() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("struct HermexSecureField"))
        XCTAssertTrue(src.contains("SecureField("), "expected HermexSecureField to keep a native SecureField editor")
    }

    // MARK: - Source contracts: shared field shell instead of duplicated chrome

    func testTextFieldAndSecureFieldShareAPrivateFieldShellRatherThanDuplicatingChrome() throws {
        let src = try hermexTextInputSource()
        XCTAssertNotNil(
            src.range(of: #"private struct Hermex\w*Shell"#, options: .regularExpression),
            "expected a single shared private field-shell type used by both HermexTextField and HermexSecureField, instead of each duplicating its own label/helper/error chrome"
        )
    }

    // MARK: - Source contracts: shared borders, radius, spacing, minimum height

    func testFieldShellConsumesSharedSurfaceBorderRoles() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("HermexSurfaceBorderColors.resting"), "expected the shared resting border role")
        XCTAssertTrue(src.contains("HermexSurfaceBorderColors.focused"), "expected the shared focused border role")
        XCTAssertTrue(src.contains("HermexSurfaceBorderColors.increasedContrast"), "expected the shared Increased Contrast border role")
    }

    func testFieldShellUsesHermesFieldRadiusAndS12Spacing() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("HermesRadius.field"), "expected the Hermex field radius token")
        XCTAssertTrue(src.contains("HermesSpacing.s12"), "expected Hermex field spacing token HermesSpacing.s12")
    }

    func testFieldShellEnforcesA44PointMinimumFieldHeight() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(
            src.contains("44") && (src.contains("minHeight") || src.contains("frame(") ),
            "expected a 44pt minimum field height"
        )
    }

    // MARK: - Source contracts: local focus and focus resignation when disabled

    func testFieldShellOwnsLocalFocusState() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("@FocusState"), "expected the field shell to own local focus state")
    }

    func testFieldShellResignsFocusWhenDisabled() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(
            src.contains("onChange(of: isEnabled)"),
            "expected the field to resign focus in response to isEnabled becoming false"
        )
    }

    // MARK: - Source contracts: visible label, helper text, and error precedence

    func testFieldShellRendersAPersistentVisibleLabel() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("Text(label)") || src.contains("Text(titleKey)"), "expected a persistent visible label above the field")
    }

    func testFieldShellAcceptsOptionalHelperTextAndOptionalErrorText() throws {
        let src = try hermexTextInputSource()
        XCTAssertTrue(src.contains("helperText: Text?"), "expected an optional caller-supplied helper text")
        XCTAssertTrue(src.contains("errorText: Text?"), "expected an optional caller-supplied error text")
    }

    func testErrorTextTakesPrecedenceOverHelperTextWhenBothArePresent() throws {
        let src = try hermexTextInputSource()
        XCTAssertNotNil(
            src.range(of: #"if let errorText[\s\S]*?\}[\s\S]*?else if let helperText"#, options: .regularExpression),
            "expected errorText to replace helperText below the field rather than both rendering together"
        )
    }

    // MARK: - Source contracts: no validation logic, error auto-clear, or password reveal

    func testHermexTextInputIntroducesNoValidationLogicOrErrorAutoClear() throws {
        let src = try hermexTextInputSource()
        XCTAssertFalse(src.contains("isValid"), "must not introduce validation logic")
        XCTAssertFalse(src.contains("onChange(of: text)"), "must not auto-clear errors as the caller types")
    }

    func testHermexSecureFieldIntroducesNoPasswordRevealToggle() throws {
        let src = try hermexTextInputSource()
        XCTAssertFalse(src.contains("isSecureTextEntry"), "must not add a password reveal toggle")
        XCTAssertFalse(src.contains("eye.slash"), "must not add a password reveal toggle")
        XCTAssertFalse(src.contains("SF Symbol"), "must not add a password reveal toggle")
    }

    // MARK: - Source contracts: Number Field removed, no multiline wrapper, no mega component

    func testHermexNumberFieldIsRemoved() throws {
        let src = try hermexTextInputSource()
        XCTAssertFalse(src.contains("HermexNumberField"), "expected HermexNumberField to be removed")
        XCTAssertFalse(src.contains("ParseableFormatStyle"), "expected the removed typed Number Field's format-style path to be gone")
        XCTAssertFalse(src.contains("TextField(titleKey, value:"), "expected the removed typed TextField(value:) path to be gone")
    }

    func testDoesNotAddAMultilineComponentOrCollapseIntoOneEnumDrivenComponent() throws {
        let src = try hermexTextInputSource()
        XCTAssertFalse(src.contains("TextEditor("), "must not add a multiline wrapper")
        XCTAssertFalse(src.contains("struct HermexTextInput:"), "must not collapse into one enum-driven mega component")
        XCTAssertFalse(src.contains("struct HermexTextInput "), "must not collapse into one enum-driven mega component")
        XCTAssertFalse(src.contains("enum HermexTextInputVariant"), "must not collapse into one enum-driven mega component")
    }

    // MARK: - DEBUG lab reachability (DSR2-06): stable, real-component Default/Password/Code
    // specimens for deterministic host-automation verification, mirroring the pattern already
    // established for Selection Sheet/Toast/Dialog/Popover Menu in HermexOverlayLab.swift.

    private func hermexOverlayLabSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
    }

    func testRemainsReachableFromTheDebugOverlayLabWithADedicatedTextInputSection() throws {
        let src = try hermexOverlayLabSource()
        XCTAssertTrue(
            src.contains("--hermex-overlay-lab-text-input"),
            "expected a deterministic launch flag scrolling straight to the Text Input fixtures"
        )
        XCTAssertTrue(
            src.contains("overlay-lab-text-input-section"),
            "expected a deterministic scroll anchor for the Text Input section"
        )
    }

    func testDebugLabExposesStableDefaultAndPasswordFixtureIdentifiers() throws {
        let src = try hermexOverlayLabSource()
        XCTAssertTrue(src.contains("overlay-lab-text-input-default"), "expected a stable identifier for the Default specimen")
        XCTAssertTrue(src.contains("overlay-lab-text-input-password"), "expected a stable identifier for the Password specimen")
    }

    func testDebugLabExposesStableCodeInputFixtureIdentifiersAtFourSixAndEightDigits() throws {
        let src = try hermexOverlayLabSource()
        XCTAssertTrue(src.contains("overlay-lab-code-input-4"), "expected a stable identifier for the 4-digit Code specimen")
        XCTAssertTrue(src.contains("overlay-lab-code-input-6-partial"), "expected a stable identifier for the partially-filled 6-digit Code specimen")
        XCTAssertTrue(src.contains("overlay-lab-code-input-6-complete"), "expected a stable identifier for the complete 6-digit Code specimen")
        XCTAssertTrue(src.contains("overlay-lab-code-input-error"), "expected a stable identifier for the errored Code specimen")
        XCTAssertTrue(src.contains("overlay-lab-code-input-disabled"), "expected a stable identifier for the disabled Code specimen")
        XCTAssertTrue(src.contains("overlay-lab-code-input-8"), "expected a stable identifier for the 8-digit Code specimen")
    }
}
