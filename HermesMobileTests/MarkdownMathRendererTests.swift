import MarkdownUI
import SwiftMath
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class MarkdownMathRendererTests: XCTestCase {
    func testMathFreeTextIsPreservedAcrossFormattingAndLayout() {
        for input in ["", "a", "\n\n", "**Bold** and `code`", "中文 العربية 👨‍👩‍👧‍👦 e\u{301}",
                      String(repeating: "A normal response.\n", count: 1_000)] {
            XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: input), input)
            XCTAssertEqual(MarkdownMathSegmenter.segments(in: input), [.markdown(input)])
            XCTAssertEqual(MarkdownMathLayoutCache.uncachedLayout(for: input), .plain(input))
        }
    }

    func testLiteralCommandsPreserveCasePrefixesAndUnicodeSuffixes() {
        XCTAssertEqual(
            MarkdownMathFormatter.replacingKnownCommands(
                in: #"\leftarrow \left x \right \Rightarrow \top \to \leq \le \neq \ne \varepsilon \epsilon"#
            ),
            "←  x  ⇒ ⊤ → ≤ ≤ ≠ ≠ ε ε"
        )
        XCTAssertEqual(
            MarkdownMathFormatter.replacingKnownCommands(in: "\\alpha\u{301} \\Alpha \\unknown"),
            "α\u{301} \\Alpha \\unknown"
        )
    }

    func testInlineAssignmentRecognitionPreservesCurrencyAndProtectedDollars() {
        let inputs = [
            "It costs $5 today.",
            #"Escaped \$E=[4,-2]\$ stays."#,
            "Unmatched $O=[6,-2] stays.",
            "Code `$P=(x,y)$` stays.",
            "```md\n$E=[4,-2]$\n```"
        ]

        for input in inputs {
            XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: input), input)
        }
    }

    func testCurrencyAmountsOnOneLineNeverPairIntoMath() {
        // Regression: two bare amounts on one line paired into an inline-math span
        // and TeX-rendered the prose between them (hyphenated words like
        // "pay-in-arrears" qualify through the operator heuristic). hermes-webui's
        // renderer rejects `$` followed by a digit as an opener; mirror that guard.
        let inputs = [
            "It was 4 visits, so $200. But the pattern all summer was pay-in-arrears (every visit lands a few days *after* a Friday mow), so $250 is the honest number.",
            "Then it's clean: **$250** — 5 visits deep, all after the fact. He's owed $250 whenever you pay next.",
            "That makes it $550 over May–Aug = 11 visits at $50 — weekly mows in peak season.",
            "It costs $5 today, and $10 tomorrow.",
            "**$5** pay-in-arrears **$10**",
            "**5 visits since the last payment** (Aug 28, Sep 11, Sep 25) → **$250**."
        ]

        for input in inputs {
            XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: input), input)
        }
    }

    func testRejectedClosingDollarDoesNotPairWithALaterSpan() {
        XCTAssertEqual(
            MarkdownMathFormatter.replacingInlineMath(in: "Loose $x^2 $ and then $y^2$ renders."),
            "Loose $x^2 $ and then y² renders."
        )
    }

    func testLetterLedInlineMathStillRendersAfterBoundaryGuards() {
        let output = MarkdownMathFormatter.replacingInlineMath(in: #"The value $x^2 + y_1$ renders."#)
        XCTAssertNotEqual(output, #"The value $x^2 + y_1$ renders."#)
        XCTAssertFalse(output.contains("$"))
        XCTAssertTrue(output.hasPrefix("The value "))
        XCTAssertTrue(output.hasSuffix(" renders."))
    }

    func testProductionLayoutsRecognizeAssignmentsForStreamingAndFinalizedMarkdown() {
        let input = #"Result: **$E=[4,-2]$** and `$O=[6,-2]$` stays code."#

        let finalized = MarkdownMathLayoutCache.layout(for: input)
        let streaming = MarkdownMathLayoutCache.uncachedLayout(for: input)

        XCTAssertEqual(finalized, streaming)
        guard case .plain(let rendered) = finalized else {
            return XCTFail("Expected inline math to keep the production renderer on its plain layout path.")
        }
        XCTAssertTrue(rendered.contains("**![\u{FFFC}](hermex-math:///RT1bNCwtMl0=)**"))
        XCTAssertTrue(rendered.contains("`$O=[6,-2]$`"))
    }

    func testDisplayMathSegmentationSkipsFencedCodeBlocks() {
        let input = #"""
        ```md
        $$\frac{1}{2}$$
        ```

        $$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$
        """#

        let mathSegments = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return latex
            }
            return nil
        }

        XCTAssertEqual(mathSegments.count, 1)
        let rendered = MarkdownMathFormatter.renderedText(for: mathSegments[0])
        XCTAssertTrue(rendered.contains("∑"))
        XCTAssertTrue(rendered.contains("∞"))
        XCTAssertTrue(rendered.contains("π²"))
    }

    func testInlineParenDelimitersRenderBeforeMarkdownEscapesThem() {
        let input = #"Inline: \(e^{i\pi}+1=0\)"#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertEqual(rendered, "Inline: eⁱπ+1=0")
        XCTAssertFalse(rendered.contains(#"\("#))
        XCTAssertFalse(rendered.contains(#"\pi"#))
    }

    func testBracketDisplayDelimitersSegmentAndRenderScreenshotExamples() {
        let input = #"""
        Block:

        \[
        \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
        \]

        Matrix:

        \[
        A = \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix},
        \quad \det(A)=1\cdot4-2\cdot3=-2
        \]

        Aligned:

        \[
        \begin{aligned} \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\ \nabla \cdot \mathbf{B} &= 0 \\ \nabla \times \mathbf{E} &= -\frac{\partial \mathbf{B}}{\partial t} \end{aligned}
        \]
        """#

        let mathSegments = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return latex
            }
            return nil
        }

        XCTAssertEqual(mathSegments.count, 3)
        let rendered = mathSegments.map(MarkdownMathFormatter.renderedText(for:))
        XCTAssertTrue(rendered[0].contains("∫₋∞^∞"))
        XCTAssertTrue(rendered[0].contains("√π"))
        XCTAssertTrue(rendered[1].contains("⎡ 1 2 ⎤"))
        XCTAssertTrue(rendered[1].contains("det(A)=1·4-2·3=-2"))
        XCTAssertTrue(rendered[2].contains("∇ · E = ρ/ε₀"))
        XCTAssertTrue(rendered[2].contains("∇ × E = -∂B/∂t"))
        XCTAssertFalse(rendered.joined().contains(#"\begin"#))
        XCTAssertFalse(rendered.joined().contains(#"\mathbf"#))
    }

    func testMarkdownHighlightPolicyLanguageLogCategoryDoesNotExposeUnsupportedLanguage() {
        let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: "password-secret-token")
        let category = MarkdownHighlightPolicy.languageLogCategory(for: normalized)

        XCTAssertEqual(category, "unsupported")
        XCTAssertFalse(category.contains("password"))
        XCTAssertFalse(category.contains("secret"))
        XCTAssertFalse(category.contains("token"))
    }

    func testMarkdownHighlightPolicySkipsMissingLanguageInsteadOfAutoDetecting() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: nil,
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .missingLanguage, normalizedLanguage: nil))
    }

    /// Diff and patch are styled natively by `MarkdownDiffFormatter`, never by Highlightr.
    func testMarkdownHighlightPolicyKeepsDiffAndPatchOutOfHighlightr() {
        for language in ["diff", "patch"] {
            XCTAssertEqual(
                MarkdownHighlightPolicy.decision(for: "@@ -1 +1 @@\n-a\n+b", language: language, isStreaming: false),
                .plain(reason: .highRiskLanguage, normalizedLanguage: language)
            )
            XCTAssertFalse(MarkdownHighlightPolicy.canHighlight(language: language))
        }
    }

    func testMarkdownHighlightPolicySkipsExtremeCodeBlocks() {
        let decision = MarkdownHighlightPolicy.decision(
            for: String(repeating: "x", count: MarkdownHighlightPolicy.maxHighlightedCodeCharacterCount + 1),
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyCharacters, normalizedLanguage: "json"))
    }

    func testMarkdownHighlightPolicySkipsExcessiveLineCounts() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\n")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "python",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyLines, normalizedLanguage: "python"))
    }

    func testMarkdownHighlightPolicySkipsLongSingleLineCode() {
        let code = String(repeating: "x", count: MarkdownHighlightPolicy.maxHighlightedCodeLineLength + 1)

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .lineTooLong, normalizedLanguage: "json"))
    }

    func testMarkdownHighlightPolicyAllowsLongCodeSplitAcrossLines() {
        let code = Array(repeating: String(repeating: "x", count: 250), count: 20)
            .joined(separator: "\r\n")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "json", engine: .highlightr))
    }

    func testMarkdownCodeHighlighterRendersLightModeSwiftForegroundColors() async {
        let result = await MarkdownCodeHighlighter().highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: "func greet(name: String) -> String {\n    return \"Hello\"\n}",
                language: "swift",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Splash to highlight Swift code.")
        }

        let colors = foregroundColorSignatures(in: highlightedCode, userInterfaceStyle: .light)
        XCTAssertGreaterThan(colors.count, 1)
    }

    func testMarkdownCodeHighlighterRendersLightModeNonSwiftForegroundColors() async {
        let result = await MarkdownCodeHighlighter().highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: """
                {
                  "enabled": true,
                  "name": "test"
                }
                """,
                language: "json",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Highlightr to highlight JSON code.")
        }

        let colors = foregroundColorSignatures(in: highlightedCode, userInterfaceStyle: .light)
        XCTAssertGreaterThan(colors.count, 1)
    }

    func testMarkdownCodeHighlighterSkipsStreamingBlocks() async {
        let result = await MarkdownCodeHighlighter().highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: #"{"value": 1}"#,
                language: "json",
                colorScheme: .light,
                isStreaming: true
            )
        )

        guard case .plain(let reason, let normalizedLanguage) = result else {
            return XCTFail("Expected streaming code to render as plain text.")
        }

        XCTAssertEqual(reason, .streaming)
        XCTAssertEqual(normalizedLanguage, "json")
    }

    func testMarkdownCodeHighlighterCachesSettledResultsForASynchronousPeek() async {
        let highlighter = MarkdownCodeHighlighter()
        let request = MarkdownCodeHighlightRequest(
            code: #"{"value": 1}"#,
            language: "json",
            colorScheme: .light,
            isStreaming: false
        )
        XCTAssertNil(highlighter.cachedHighlight(for: request))

        guard case .highlighted(let first) = await highlighter.highlightedCode(for: request),
              case .highlighted(let second) = await highlighter.highlightedCode(for: request) else {
            return XCTFail("Expected Highlightr to highlight JSON code.")
        }

        // A remount reads the stored result instead of running highlight.js again.
        XCTAssertTrue(highlighter.cachedHighlight(for: request) === first)
        XCTAssertTrue(second === first)
    }

    func testMarkdownCodeHighlighterCacheIsKeyedByAppearanceAndSkipsStreaming() async {
        let highlighter = MarkdownCodeHighlighter()
        let code = "let value = 1"
        let light = MarkdownCodeHighlightRequest(code: code, language: "swift", colorScheme: .light, isStreaming: false)
        _ = await highlighter.highlightedCode(for: light)

        XCTAssertNotNil(highlighter.cachedHighlight(for: light))
        XCTAssertNil(highlighter.cachedHighlight(
            for: MarkdownCodeHighlightRequest(code: code, language: "swift", colorScheme: .dark, isStreaming: false)
        ))
        XCTAssertNil(highlighter.cachedHighlight(
            for: MarkdownCodeHighlightRequest(code: code, language: "swift", colorScheme: .light, isStreaming: true)
        ))
    }

    func testMarkdownCodeHighlighterCacheKeySeparatesLanguageFromCode() async {
        let highlighter = MarkdownCodeHighlighter()
        // Both fences normalize to Swift; a plain `language|code` key would read "swift a|b|c" for each.
        let cached = MarkdownCodeHighlightRequest(code: "b|c", language: "swift a", colorScheme: .light, isStreaming: false)
        _ = await highlighter.highlightedCode(for: cached)

        XCTAssertNotNil(highlighter.cachedHighlight(for: cached))
        XCTAssertNil(highlighter.cachedHighlight(
            for: MarkdownCodeHighlightRequest(code: "c", language: "swift a|b", colorScheme: .light, isStreaming: false)
        ))
    }

    func testMarkdownCodeHighlighterSkipsThePassForACancelledTask() async {
        let highlighter = MarkdownCodeHighlighter()
        let request = MarkdownCodeHighlightRequest(
            code: #"{"value": 1}"#,
            language: "json",
            colorScheme: .light,
            isStreaming: false
        )
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await highlighter.highlightedCode(for: request)
        }.value

        guard case .plain(let reason, _) = result else {
            return XCTFail("Expected a cancelled task to skip highlighting.")
        }
        XCTAssertEqual(reason, .cancelled)
        XCTAssertNil(highlighter.cachedHighlight(for: request))
    }

    func testMarkdownPlainCodeFormatterPreservesVisibleBlankLines() {
        let lines = MarkdownPlainCodeFormatter.lines(in: "first\n\nthird")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].segments.map(\.text), ["first"])
        XCTAssertEqual(lines[1].segments.map(\.text), [" "])
        XCTAssertEqual(lines[2].segments.map(\.text), ["third"])
    }

    func testMarkdownPlainCodeFormatterSegmentsVeryLongLines() {
        let longLine = String(repeating: "x", count: MarkdownPlainCodeFormatter.maxSegmentLength + 12)
        let lines = MarkdownPlainCodeFormatter.lines(in: longLine)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].segments.count, 2)
        XCTAssertEqual(lines[0].segments[0].text.count, MarkdownPlainCodeFormatter.maxSegmentLength)
        XCTAssertEqual(lines[0].segments[1].text.count, 12)
    }

    func testMarkdownAttributedCodeFormatterSegmentsVeryLongHighlightedLines() {
        let longLine = String(repeating: "x", count: MarkdownAttributedCodeFormatter.maxSegmentLength + 12)
        let attributedCode = NSAttributedString(string: "first\n\(longLine)")

        let lines = MarkdownAttributedCodeFormatter.lines(in: attributedCode)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].segments.map(\.attributedText.string), ["first"])
        XCTAssertEqual(lines[1].segments.count, 2)
        XCTAssertEqual(
            lines[1].segments[0].attributedText.string.count,
            MarkdownAttributedCodeFormatter.maxSegmentLength
        )
        XCTAssertEqual(lines[1].segments[1].attributedText.string.count, 12)
    }

    func testMarkdownAttributedCodeFormatterPreservesForegroundColors() {
        let attributedCode = NSMutableAttributedString(
            string: "let value = true",
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.label
            ]
        )
        attributedCode.addAttributes(
            [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.systemPink
            ],
            range: NSRange(location: 0, length: 3)
        )
        attributedCode.addAttribute(
            .foregroundColor,
            value: UIColor.systemBlue,
            range: NSRange(location: 12, length: 4)
        )

        let segments = MarkdownAttributedCodeFormatter.lines(in: attributedCode)
            .flatMap(\.segments)

        XCTAssertEqual(segments.map(\.attributedText.string), ["let value = true"])
        XCTAssertGreaterThan(
            foregroundColorSignatures(in: segments[0].attributedText, userInterfaceStyle: .light).count,
            1
        )

        let firstFont = segments[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(firstFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertEqual(
            colorSignature(in: segments[0].attributedText, at: 0, userInterfaceStyle: .light),
            colorSignature(for: .systemPink, userInterfaceStyle: .light)
        )
        XCTAssertEqual(
            colorSignature(in: segments[0].attributedText, at: 12, userInterfaceStyle: .light),
            colorSignature(for: .systemBlue, userInterfaceStyle: .light)
        )
    }

    func testMarkdownContentRenderingPolicyFallsBackForVeryLargeMarkdown() {
        let content = String(
            repeating: "a",
            count: MarkdownContentRenderingPolicy.maxMarkdownCharacterCount + 1
        )

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyCharacters
        )
    }

    func testMarkdownContentRenderingPolicyFallsBackForTooManyLines() {
        let content = Array(
            repeating: "line",
            count: MarkdownContentRenderingPolicy.maxMarkdownLineCount + 1
        )
        .joined(separator: "\n")

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyLines
        )
    }

    func testMarkdownContentRenderingPolicyFallsBackForCarriageReturnLines() {
        let content = Array(
            repeating: "line",
            count: MarkdownContentRenderingPolicy.maxMarkdownLineCount + 1
        )
        .joined(separator: "\r")

        XCTAssertEqual(
            MarkdownContentRenderingPolicy.fallbackReason(for: content),
            .tooManyLines
        )
    }
}

private func foregroundColorSignatures(in attributedString: NSAttributedString, userInterfaceStyle: UIUserInterfaceStyle) -> Set<String> {
    var colors: Set<String> = []
    attributedString.enumerateAttribute(
        .foregroundColor,
        in: NSRange(location: 0, length: attributedString.length)
    ) { value, _, _ in
        guard let color = value as? UIColor,
              let signature = colorSignature(for: color, userInterfaceStyle: userInterfaceStyle) else {
            return
        }

        colors.insert(signature)
    }
    return colors
}

private func colorSignature(for color: UIColor?, userInterfaceStyle: UIUserInterfaceStyle) -> String? {
    guard let color else { return nil }

    let resolvedColor = color.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
    )
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0

    if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
        return [red, green, blue, alpha]
            .map { String(format: "%.3f", Double($0)) }
            .joined(separator: ",")
    }

    var white: CGFloat = 0
    if resolvedColor.getWhite(&white, alpha: &alpha) {
        return [white, alpha]
            .map { String(format: "%.3f", Double($0)) }
            .joined(separator: ",")
    }

    return nil
}

private func colorSignature(in attributedString: NSAttributedString, at location: Int, userInterfaceStyle: UIUserInterfaceStyle) -> String? {
    colorSignature(
        for: attributedString.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor,
        userInterfaceStyle: userInterfaceStyle
    )
}

final class MathFenceLanguageTests: XCTestCase {
    func testMatchingIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(MathFenceLanguage.matches("Math"))
        XCTAssertTrue(MathFenceLanguage.matches("  LaTeX  "))
        XCTAssertTrue(MathFenceLanguage.matches("TEX"))
    }

    func testFirstInfoTokenIsUsed() {
        // Markdown info strings can carry extra tokens after the language.
        XCTAssertTrue(MathFenceLanguage.matches("math title=Quadratic"))
    }
}


enum Issue447Fixture {
    static let markdown = #"""
    1. **Bridge fix** — your restatement of the $\Phi\Phi^*$ fixed-point sentence (the one that came out as "vectors of K rows").
    2. **Contrast set** — $(4,-2)$ against $(4,4)$, the computation half the block lives in.
    3. **Units table** — rate vs frequency vs duration, the third-strike fault.
    4. **Block A in exam form** — the 2022 Q3(d) phrasing: *"determine the set of vectors recovered after sampling with $M_S$ and subsequent interpolation"* — you write it as you'd hand it in.

    Also due from the queue: FIR/IIR and convolution-theorem/Parseval — those ride after, block D day. Lecture 6 §3.2–3.5 and §5.7 are the reference trail for all of it; I'll pull the exact pages when we land on something worth citing.

    Item 1, right now — restatement, no help from me. The setup: $C$ orthogonal, $M_S$ keeps the first $K$ rows, $M_I = M_S^*$.

    $$M_I\,M_S\,x = x$$

    Which vectors $x$ come back exactly — and what is that set of vectors called?

    Confidence first: low / medium / high?
    """#
}

extension MarkdownMathRendererTests {
    func testExactReportedMarkdownKeepsAllInlineExpressionsAndListFlow() throws {
        let layout = MarkdownMathLayoutCache.uncachedLayout(for: Issue447Fixture.markdown)
        XCTAssertEqual(layout, MarkdownMathLayoutCache.layout(for: Issue447Fixture.markdown))
        guard case .segmented(let segments) = layout else { return XCTFail("Expected the reported display equation") }
        var expressions: [String] = []
        for segment in segments {
            if case .markdown(let markdown) = segment {
                let attributed = try AttributedString(markdown: markdown)
                expressions += attributed.runs.compactMap { $0.imageURL.flatMap(InlineMathSource.latex) }
            }
        }
        XCTAssertEqual(expressions, [#"\Phi\Phi^*"#, "(4,-2)", "(4,4)", "M_S", "C", "M_S", "K", "M_I = M_S^*", "x"])
        XCTAssertEqual(segments.filter { if case .displayMath = $0 { return true }; return false }, [.displayMath(#"M_I\,M_S\,x = x"#)])
        guard case .markdown(let list) = segments[0] else { return XCTFail("Expected the numbered list") }
        XCTAssertTrue(list.contains("1. **Bridge fix**"))
        XCTAssertTrue(list.contains("4. **Block A in exam form**"))
        XCTAssertTrue(list.contains("*\"determine the set of vectors recovered after sampling with ![\u{FFFC}]("))
    }

    func testImageFormattingPreservesLiteralAndPartialTokens() {
        for input in [#"Cost $5 today and $7 tomorrow."#, #"\$M_S\$"#, "`$M_S$`",
                      "```tex\n$M_S$\n```", #"Unfinished $\Phi"#, #"Unfinished \(M_S"#,
                      "$$partial", "${unfinished", #"Code `$(4,4)$`"#] {
            XCTAssertEqual(MarkdownMathFormatter.inlineMathImages(in: input), input)
        }
        let prefixes = [#"$\Phi"#, #"$\Phi\Phi^"#, #"$\Phi\Phi^*"#]
        for prefix in prefixes {
            XCTAssertEqual(MarkdownMathLayoutCache.uncachedLayout(for: prefix), .plain(prefix))
        }
        XCTAssertEqual(MarkdownMathFormatter.inlineMathImages(in: #"$\Phi\Phi^*$"#), "![\u{FFFC}](hermex-math:///XFBoaVxQaGleKg==)")
    }

    @MainActor
    func testNestedInlineMathRetainsSurroundingTextAndExcludesEquationsFromSelection() async throws {
        let markdown = MarkdownMathFormatter.inlineMathImages(in: #"*Determine $M_S$ and $M_I = M_S^*$ now.* `code` and [link](https://example.com)."#)
        let result = try await InlineMathTextRequest(markdown: markdown, fontSize: 16, dark: false, scale: 3).render()
        XCTAssertEqual(result.selectableText, "Determine  and  now. code and link.")
        XCTAssertEqual(result.accessibilityText, "Determine M_S and M_I = M_S^* now. code and link.")
    }

    func testInlineImagesReuseTypesettingAndSeparateRasterInputs() async throws {
        let cache = InlineMathImageCache()
        let first = try await cache.image(latex: "M_S", fontSize: 16, dark: false, scale: 3)
        for _ in 0..<30 {
            let next = try await cache.image(latex: "M_S", fontSize: 16, dark: false, scale: 3)
            XCTAssertTrue(first === next, "Token updates must reuse the unchanged expression")
        }
        let count = await cache.renderCount
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(first.baselineOffsetFromBottom), 0, "Uppercase subscript must extend below the prose baseline")
        let large = try await cache.image(latex: "M_S", fontSize: 32, dark: false, scale: 3)
        XCTAssertGreaterThan(large.size.height, first.size.height * 1.8)
        _ = try await cache.image(latex: "M_S", fontSize: 16, dark: true, scale: 3)
        let retina = try await cache.image(latex: "M_S", fontSize: 16, dark: false, scale: 2)
        XCTAssertEqual(retina.scale, 2)
        let finalCount = await cache.renderCount
        XCTAssertEqual(finalCount, 4)
    }

    func testCancelledInlineRenderingDoesNotPopulateExpressionCache() async throws {
        let cache = InlineMathImageCache()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.image(latex: #"\Phi\Phi^*"#, fontSize: 16, dark: false, scale: 3)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work should be discarded")
        } catch is CancellationError {}
        let count = await cache.renderCount
        XCTAssertEqual(count, 0)
    }

    func testUnsupportedInlineCommandUsesReadableLiteralFallback() async throws {
        let cache = InlineMathImageCache()
        let image = try await cache.image(latex: #"\notARealCommand{x}"#, fontSize: 16, dark: false, scale: 3)
        let expectedWidth = (#"$\notARealCommand{x}$"# as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 16)]).width
        XCTAssertEqual(image.size.width, ceil(expectedWidth), accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(image.baselineOffsetFromBottom), 0)
    }
}


extension MarkdownMathRendererTests {
    @MainActor
    func testNormalImageProviderKeepsItsURLAndAltTextBesideMath() async throws {
        let fallback = InlineImageProviderProbe()
        let provider = InlineMathImageProvider(fontSize: 16, colorScheme: .light, scale: 3, fallback: fallback)
        let request = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "Before $M_S$ and ![workspace screenshot](https://example.com/image.png) after."),
            fontSize: 16, dark: false, scale: 3
        )
        let result = try await request.render(provider: provider)
        let requests = await fallback.requests
        XCTAssertEqual(requests.map(\.0), [URL(string: "https://example.com/image.png")!])
        XCTAssertEqual(requests.map(\.1), ["workspace screenshot"])
        XCTAssertEqual(result.selectableText, "Before  and  after.")
        XCTAssertEqual(result.accessibilityText, "Before M_S and workspace screenshot after.")
    }

    @MainActor
    func testFailedOrdinaryImageKeepsSurroundingMathAndProse() async throws {
        let fallback = InlineImageProviderProbe(fails: true)
        let provider = InlineMathImageProvider(fontSize: 16, colorScheme: .light, scale: 3, fallback: fallback)
        let result = try await InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "Before $M_S$ ![photo](https://example.com/missing.png) after."),
            fontSize: 16, dark: false, scale: 3
        ).render(provider: provider)
        XCTAssertEqual(result.selectableText, "Before   after.")
        XCTAssertEqual(result.accessibilityText, "Before M_S photo after.")
    }

    @MainActor
    func testIncrementalMathKeepsSealedChunksAndTypesetsEachExpressionOnce() async throws {
        let head = String(repeating: "Sealed transcript paragraph.\n\n", count: 250)
        var tail = "A $Q_{447}$ tail"
        let before = await InlineMathImageCache.shared.renderCount
        let initial = StreamingMarkdownBlockSplitter.split(MarkdownMathFormatter.inlineMathImages(in: head + tail))
        XCTAssertEqual(initial.stableChunks.count, 1)
        var synchronousHits = 0
        for _ in 0..<30 {
            tail += " next"
            let source = head + tail
            guard case .plain(let markdown) = MarkdownMathLayoutCache.uncachedLayout(for: source) else {
                return XCTFail("Inline math should not introduce a display block")
            }
            let split = StreamingMarkdownBlockSplitter.split(markdown)
            XCTAssertEqual(split.stableChunks, initial.stableChunks, "Tokens must not invalidate sealed chunks or their IDs")
            let request = InlineMathTextRequest(markdown: split.activeMarkdown, fontSize: 16, dark: false, scale: 3)
            if try request.cachedResult() != nil {
                synchronousHits += 1
            } else {
                _ = try await request.render()
            }
            XCTAssertFalse(MarkdownMathLayoutCache.hasCachedLayout(for: source))
        }
        let after = await InlineMathImageCache.shared.renderCount
        XCTAssertEqual(after - before, 1, "Thirty appends should rasterize the unchanged expression exactly once")
        XCTAssertEqual(synchronousHits, 29, "Warm updates must avoid async loading and state publication")
    }
}

private actor InlineImageProviderProbe: InlineImageProvider {
    let fails: Bool
    private(set) var requests: [(URL, String)] = []
    init(fails: Bool = false) { self.fails = fails }
    func image(with url: URL, label: String) async throws -> Image {
        requests.append((url, label))
        if fails { throw URLError(.fileDoesNotExist) }
        return Image(systemName: "square")
    }
}


extension MarkdownMathRendererTests {
    @MainActor
    func testLinkedEquationsAndImagesPreserveDestinationsWithReadableFallbacks() async throws {
        let request = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "[$M_S$](https://example.com/equation)"),
            fontSize: 16, dark: false, scale: 3
        )
        let parsed = try request.parsed()
        XCTAssertEqual(parsed.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/equation"])
        XCTAssertEqual(parsed.runs.compactMap { $0.imageURL.flatMap(InlineMathSource.latex) }, ["M_S"])
        let result = try await request.render()
        var expected = AttributedString("M_S")
        expected.link = URL(string: "https://example.com/equation")
        XCTAssertEqual(result.text, Text("") + Text(expected).customAttribute(ResponseSelectionImageAttribute()))
        XCTAssertEqual(result.selectableText, "")
        XCTAssertEqual(result.accessibilityText, "M_S")

        let imageRequest = InlineMathTextRequest(
            markdown: "[![workspace screenshot](https://example.com/image.png)](https://example.com/photo)",
            fontSize: 16, dark: false, scale: 3
        )
        let image = try await imageRequest.render(provider: InlineImageProviderProbe())
        var imageLink = AttributedString("workspace screenshot")
        imageLink.link = URL(string: "https://example.com/photo")
        XCTAssertEqual(image.text, Text("") + Text(imageLink).customAttribute(ResponseSelectionImageAttribute()))
        XCTAssertEqual(image.selectableText, "")
        XCTAssertEqual(image.accessibilityText, "workspace screenshot")
    }

    func testLinkedImageRecoveryPreservesSurroundingCodeAndMultilineUnicode() throws {
        let request = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "é [**see $M_S$**](https://example.com/math) and `![](literal)` [![two\nlines](https://example.com/image.png)](https://example.com/photo)"),
            fontSize: 16, dark: false, scale: 3
        )
        let parsed = try request.parsed()
        XCTAssertEqual(parsed.runs.compactMap(\.imageURL).map(\.absoluteString),
                       ["hermex-math:///TV9T", "https://example.com/image.png"])
        XCTAssertTrue(String(parsed.characters).contains("![](literal)"))
        XCTAssertEqual(parsed.runs.filter { $0.imageURL != nil }.compactMap(\.link).map(\.absoluteString),
                       ["https://example.com/math", "https://example.com/photo"])
    }
}


extension MarkdownMathRendererTests {
    @MainActor
    func testStreamingMathAndOrdinaryImagesReuseAssetsWithCurrentText() async throws {
        let fallback = InlineImageProviderProbe()
        let provider = InlineMathImageProvider(fontSize: 16, colorScheme: .light, scale: 3, fallback: fallback)
        var source = "Before $M_S$ ![photo](https://example.com/image.png) after"
        func request(_ source: String) -> InlineMathTextRequest {
            .init(markdown: MarkdownMathFormatter.inlineMathImages(in: source), fontSize: 16, dark: false, scale: 3)
        }
        let first = request(source)
        let identity = try first.imageLoadIdentity()
        let loaded = try await first.render(provider: provider)
        for _ in 0..<30 {
            source += " next"
            let current = request(source)
            XCTAssertEqual(try current.imageLoadIdentity(), identity, "Token appends must not cancel an in-flight image load")
            let result = try XCTUnwrap(current.cachedResult(images: loaded.images))
            XCTAssertEqual(result.accessibilityText, source.replacingOccurrences(of: "$M_S$", with: "M_S")
                .replacingOccurrences(of: "![photo](https://example.com/image.png)", with: "photo"))
            XCTAssertEqual(result.selectableText, source.replacingOccurrences(of: "$M_S$", with: "")
                .replacingOccurrences(of: "![photo](https://example.com/image.png)", with: ""))
        }
        let requests = await fallback.requests
        XCTAssertEqual(requests.map(\.0), [URL(string: "https://example.com/image.png")!])
        XCTAssertEqual(requests.map(\.1), ["photo"])
        let removed = try request("Only $M_S$ remains").cachedResult(images: loaded.images)
        XCTAssertEqual(removed?.images.count, 1, "Per-leaf image state must discard removed sources")
    }

    @MainActor
    func testColdFormulaUsesCurrentPlaceholderWithoutDroppingLoadedImages() async throws {
        let old = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "Before $M_S$ ![photo](https://example.com/image.png)"),
            fontSize: 16, dark: false, scale: 3
        )
        let loaded = try await old.render(provider: InlineImageProviderProbe())
        let current = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "Before $M_S$ ![photo](https://example.com/image.png) latest $Q_{989,2}$ tail"),
            fontSize: 16, dark: false, scale: 3
        )
        XCTAssertNil(try current.cachedResult(images: loaded.images))
        let placeholder = try current.placeholder(images: loaded.images)
        XCTAssertEqual(placeholder.accessibilityText, "Before M_S photo latest Q_{989,2} tail")
        XCTAssertEqual(placeholder.selectableText, "Before   latest  tail")
        XCTAssertEqual(placeholder.images[URL(string: "https://example.com/image.png")!], Image(systemName: "square"))
        XCTAssertNotEqual(try current.imageLoadIdentity(), try old.imageLoadIdentity())
    }
}


extension MarkdownMathRendererTests {
    @MainActor
    func testFailedImagesRetryWithoutReloadingSuccessfulAssets() async throws {
        let provider = RetryingInlineImageProvider(failures: 1)
        let request = InlineMathTextRequest(
            markdown: MarkdownMathFormatter.inlineMathImages(in: "$M_S$ ![good](https://example.com/good.png) ![retry](https://example.com/retry.png)"),
            fontSize: 16, dark: false, scale: 3
        )
        var waits: [Int] = []
        var availableCounts: [Int] = []
        try await request.renderWithRetries(provider: provider, beforeRetry: { waits.append($0) }) { result in
            availableCounts.append(result.images.count)
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.0), ["hermex-math:///TV9T", "https://example.com/good.png", "https://example.com/retry.png", "https://example.com/retry.png"])
        XCTAssertEqual(requests.map(\.1), ["\u{FFFC}", "good", "retry", "retry"])
        XCTAssertEqual(waits, [1])
        XCTAssertEqual(availableCounts, [2, 3], "Successful assets should be published before retrying the missing image")
    }

    @MainActor
    func testPermanentImageFailureHasABoundedRetryBudget() async throws {
        let provider = RetryingInlineImageProvider(failures: 10)
        let request = InlineMathTextRequest(markdown: "![retry](https://example.com/retry.png)", fontSize: 16, dark: false, scale: 3)
        var waits: [Int] = []
        var labels: [String] = []
        try await request.renderWithRetries(provider: provider, beforeRetry: { waits.append($0) }) { result in
            labels.append(result.accessibilityText)
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.0), Array(repeating: "https://example.com/retry.png", count: 3))
        XCTAssertEqual(waits, [1, 2])
        XCTAssertEqual(labels, ["retry", "retry", "retry"])
    }

    @MainActor
    func testCancellationDuringImageBackoffStopsRequestsAndPublication() async throws {
        let provider = RetryingInlineImageProvider(failures: 10)
        let request = InlineMathTextRequest(markdown: "![retry](https://example.com/retry.png)", fontSize: 16, dark: false, scale: 3)
        var publications = 0
        let task = Task {
            try await request.renderWithRetries(provider: provider, beforeRetry: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }) { _ in publications += 1 }
        }
        do {
            try await task.value
            XCTFail("Cancellation should leave the retry loop")
        } catch is CancellationError {}
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.0), ["https://example.com/retry.png"])
        XCTAssertEqual(publications, 1, "No result may publish after the owning task is cancelled")
    }
}

private actor RetryingInlineImageProvider: InlineImageProvider {
    private var failures: Int
    private(set) var requests: [(String, String)] = []
    init(failures: Int) { self.failures = failures }
    func image(with url: URL, label: String) async throws -> Image {
        requests.append((url.absoluteString, label))
        if url.lastPathComponent == "retry.png", failures > 0 {
            failures -= 1
            throw URLError(.networkConnectionLost)
        }
        return Image(systemName: "square")
    }
}
