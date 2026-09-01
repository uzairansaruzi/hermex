import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class MarkdownMathRendererTests: XCTestCase {
    func testInlineMathReplacesCommonLatexCommands() {
        let input = #"Inline: the quadratic formula $x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$ works."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertFalse(rendered.contains("$"))
        XCTAssertFalse(rendered.contains(#"\frac"#))
        XCTAssertFalse(rendered.contains(#"\sqrt"#))
        XCTAssertTrue(rendered.contains("±"))
        XCTAssertTrue(rendered.contains("√"))
        XCTAssertTrue(rendered.contains("²"))
    }

    func testSingleTokenInlineMathAndEscapedDollars() {
        let input = #"Where $m$ is count, $y$ is label, and \$not math\$ stays literal."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains("Where m is count"))
        XCTAssertTrue(rendered.contains("y is label"))
        XCTAssertTrue(rendered.contains(#"\$not math\$"#))
    }

    func testInlineAssignmentsRecognizeVectorsTuplesAndExistingScriptForms() {
        let input = #"Vectors $E=[4,-2]$ and $O=[6,-2]$; tuple $P=(x,y)$; scripts $W_0=e^0$, $W_2$, $O_0$, and $X_0=\sum x_n$."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertFalse(rendered.contains("$"))
        XCTAssertTrue(rendered.contains("E=[4,-2]"))
        XCTAssertTrue(rendered.contains("O=[6,-2]"))
        XCTAssertTrue(rendered.contains("P=(x,y)"))
        XCTAssertTrue(rendered.contains("W₀=e⁰"))
        XCTAssertTrue(rendered.contains("W₂"))
        XCTAssertTrue(rendered.contains("O₀"))
        XCTAssertTrue(rendered.contains("X₀=∑ xₙ"))
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

    func testProductionLayoutsRecognizeAssignmentsForStreamingAndFinalizedMarkdown() {
        let input = #"Result: **$E=[4,-2]$** and `$O=[6,-2]$` stays code."#

        let finalized = MarkdownMathLayoutCache.layout(for: input)
        let streaming = MarkdownMathLayoutCache.uncachedLayout(for: input)

        XCTAssertEqual(finalized, streaming)
        guard case .plain(let rendered) = finalized else {
            return XCTFail("Expected inline math to keep the production renderer on its plain layout path.")
        }
        XCTAssertTrue(rendered.contains("**E=[4,-2]**"))
        XCTAssertTrue(rendered.contains("`$O=[6,-2]$`"))
    }

    func testInlineScreenshotCommandsDoNotLeakRawLatex() {
        let input = #"Probability: $P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}$ and norm $\Vert x \rVert_2 = \sqrt{\sum_{i=1}^n x_i^2}$."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertFalse(rendered.contains(#"\mid"#))
        XCTAssertFalse(rendered.contains(#"\Vert"#))
        XCTAssertFalse(rendered.contains(#"\rVert"#))
        XCTAssertTrue(rendered.contains("P(A | B)"))
        XCTAssertTrue(rendered.contains("‖ x ‖₂"))
        XCTAssertTrue(rendered.contains("∑ᵢ₌₁ⁿ"))
        XCTAssertTrue(rendered.contains("xᵢ²"))
    }

    func testLongerCommandsWinBeforeShorterCommandPrefixes() {
        let input = #"Attention: $\mathrm{softmax}(QK^\top/\sqrt{d_k})V$ and $a \leftarrow b \to c$."#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains("QK^⊤/√dₖ"))
        XCTAssertTrue(rendered.contains("a ← b → c"))
        XCTAssertFalse(rendered.contains("→p"))
        XCTAssertFalse(rendered.contains(#"\top"#))
        XCTAssertFalse(rendered.contains(#"\leftarrow"#))
    }

    func testDisplayMathSegmentsAndRendersMatrices() {
        let input = #"**Matrices** $$\begin{pmatrix} a & b \\ c & d \end{pmatrix}^{-1} = \frac{1}{ad-bc}\begin{pmatrix} d & -b \\ -c & a \end{pmatrix}$$"#

        let segments = MarkdownMathSegmenter.segments(in: input)

        XCTAssertEqual(segments.count, 2)
        guard case .displayMath(let latex) = segments.last else {
            return XCTFail("Expected trailing display math segment.")
        }

        let rendered = MarkdownMathFormatter.renderedText(for: latex)
        XCTAssertFalse(rendered.contains("$"))
        XCTAssertFalse(rendered.contains(#"\begin"#))
        XCTAssertTrue(rendered.contains("⎛"))
        XCTAssertTrue(rendered.contains("⎞"))
        XCTAssertTrue(rendered.contains("⁻¹"))
        XCTAssertTrue(rendered.contains("ad-bc"))
    }

    func testInlineMathSkipsCodeSpansAndFencedBlocks() {
        let input = #"""
        Code `$x = \frac{1}{2}$` stays.

        ```swift
        let value = "$$\\frac{1}{2}$$"
        ```

        But $x^2$ changes.
        """#

        let rendered = MarkdownMathFormatter.replacingInlineMath(in: input)

        XCTAssertTrue(rendered.contains(#"`$x = \frac{1}{2}$`"#))
        XCTAssertTrue(rendered.contains(#"$$\\frac{1}{2}$$"#))
        XCTAssertTrue(rendered.contains("x²"))
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

    func testFinalStressTestDoesNotLeakRawCommands() {
        let input = #"""
        \[
        \boxed{
        \mathcal{L}(\theta)
        =
        -\sum_{i=1}^{n}
        [
        y_i \log \hat{y}_i
        +
        (1-y_i)\log(1-\hat{y}_i)
        ]
        }
        \]
        """#

        guard case .displayMath(let latex) = MarkdownMathSegmenter.segments(in: input).first else {
            return XCTFail("Expected display math.")
        }

        let rendered = MarkdownMathFormatter.renderedText(for: latex)

        XCTAssertTrue(rendered.contains("ℒ(θ)"))
        XCTAssertTrue(rendered.contains("-∑ᵢ₌₁ⁿ"))
        XCTAssertTrue(rendered.contains("yᵢ log ŷᵢ"))
        XCTAssertTrue(rendered.contains("(1-yᵢ)log(1-ŷᵢ)"))
        XCTAssertFalse(rendered.contains(#"\boxed"#))
        XCTAssertFalse(rendered.contains(#"\mathcal"#))
        XCTAssertFalse(rendered.contains(#"\log"#))
        XCTAssertFalse(rendered.contains(#"\hat"#))
    }

    func testCasesAndOptimizationCommandsRenderFromDisplayMath() {
        let input = #"""
        \[
        \begin{cases}
        2x + y = 5 \\
        x - y = 1
        \end{cases}
        \Rightarrow x = 2, y = 1
        \]

        \[
        \theta^* = \arg\min_{\theta} \frac{1}{n}\sum_{i=1}^{n}(y_i - f_\theta(x_i))^2
        \]

        \[
        \theta^\* = \arg\min_{\theta} J(\theta)
        \]
        """#

        let rendered = MarkdownMathSegmenter.segments(in: input).compactMap { segment -> String? in
            if case .displayMath(let latex) = segment {
                return MarkdownMathFormatter.renderedText(for: latex)
            }
            return nil
        }
        .joined(separator: "\n")

        XCTAssertTrue(rendered.contains("⎧ 2x + y = 5"))
        XCTAssertTrue(rendered.contains("⎩ x - y = 1"))
        XCTAssertTrue(rendered.contains("⇒ x = 2, y = 1"))
        XCTAssertTrue(rendered.contains("θ^* = argminθ"))
        XCTAssertFalse(rendered.contains(#"θ^\*"#))
        XCTAssertTrue(rendered.contains("∑ᵢ₌₁ⁿ"))
        XCTAssertFalse(rendered.contains(#"\begin"#))
        XCTAssertFalse(rendered.contains(#"\end"#))
        XCTAssertFalse(rendered.contains(#"\Rightarrow"#))
        XCTAssertFalse(rendered.contains(#"\arg"#))
    }

    func testMarkdownHighlightPolicyUsesSplashForNormalSwiftCode() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: "swift",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "swift", engine: .splashSwift))
    }

    func testMarkdownHighlightPolicyNormalizesCommonAliases() {
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "py"), "python")
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "zsh session"), "bash")
        XCTAssertEqual(MarkdownHighlightPolicy.normalizedLanguage(from: "TSX"), "typescript")
    }

    func testMarkdownHighlightPolicyLanguageLogCategoryDoesNotExposeUnsupportedLanguage() {
        let normalized = MarkdownHighlightPolicy.normalizedLanguage(from: "password-secret-token")
        let category = MarkdownHighlightPolicy.languageLogCategory(for: normalized)

        XCTAssertEqual(category, "unsupported")
        XCTAssertFalse(category.contains("password"))
        XCTAssertFalse(category.contains("secret"))
        XCTAssertFalse(category.contains("token"))
    }

    func testMarkdownHighlightPolicyLanguageLogCategoryUsesFixedBuckets() {
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: nil), "missing")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "swift"), "splashSwift")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "json"), "highlightr")
        XCTAssertEqual(MarkdownHighlightPolicy.languageLogCategory(for: "log"), "highRisk")
    }

    func testMarkdownHighlightPolicySkipsStreamingCode() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: "swift",
            isStreaming: true
        )

        XCTAssertEqual(decision, .plain(reason: .streaming, normalizedLanguage: "swift"))
    }

    func testMarkdownHighlightPolicySkipsMissingLanguageInsteadOfAutoDetecting() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "let value = 1",
            language: nil,
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .missingLanguage, normalizedLanguage: nil))
    }

    func testMarkdownHighlightPolicySkipsLogLikeLanguages() {
        let decision = MarkdownHighlightPolicy.decision(
            for: "2026-05-26 warning: retrying",
            language: "log",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .highRiskLanguage, normalizedLanguage: "log"))
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

    func testMarkdownHighlightPolicyCountsCarriageReturnLines() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\r")

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "python",
            isStreaming: false
        )

        XCTAssertEqual(decision, .plain(reason: .tooManyLines, normalizedLanguage: "python"))
    }

    func testMarkdownHighlightPolicyCountsUnicodeSeparatorLines() {
        let code = Array(repeating: "print(1)", count: MarkdownHighlightPolicy.maxHighlightedCodeLineCount + 1)
            .joined(separator: "\u{2028}")

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

    @MainActor
    func testMarkdownCodeHighlighterRendersSwiftCodeWithSplash() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: "let value = 1",
                language: "swift",
                colorScheme: .light,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Splash to highlight Swift code.")
        }

        XCTAssertEqual(highlightedCode.string, "let value = 1")
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersLightModeSwiftForegroundColors() {
        let result = MarkdownCodeHighlighter.highlightedCode(
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

    @MainActor
    func testMarkdownCodeHighlighterRendersNonSwiftCodeWithHighlightr() {
        let result = MarkdownCodeHighlighter.highlightedCode(
            for: MarkdownCodeHighlightRequest(
                code: #"{"value": 1}"#,
                language: "json",
                colorScheme: .dark,
                isStreaming: false
            )
        )

        guard case .highlighted(let highlightedCode) = result else {
            return XCTFail("Expected Highlightr to highlight JSON code.")
        }

        let renderedCode = highlightedCode.string
        XCTAssertTrue(renderedCode.contains("value"))
        XCTAssertTrue(renderedCode.contains("1"))
    }

    @MainActor
    func testMarkdownCodeHighlighterRendersLightModeNonSwiftForegroundColors() {
        let result = MarkdownCodeHighlighter.highlightedCode(
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

    @MainActor
    func testMarkdownCodeHighlighterSkipsStreamingBlocks() {
        let result = MarkdownCodeHighlighter.highlightedCode(
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

    func testMarkdownHighlightPolicyAllowsLargeCodeBlocksWithinMarkdownLimit() {
        let code = Array(
            repeating: #""enabled": true, "retries": 5, "mode": "verbose""#,
            count: 350
        )
        .joined(separator: "\n")

        XCTAssertGreaterThan(code.count, 12_000)

        let decision = MarkdownHighlightPolicy.decision(
            for: code,
            language: "json",
            isStreaming: false
        )

        XCTAssertEqual(decision, .highlight(language: "json", engine: .highlightr))
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

    func testMarkdownContentRenderingPolicyAllowsNormalMarkdown() {
        XCTAssertNil(MarkdownContentRenderingPolicy.fallbackReason(for: "**Hello** world"))
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
    func testMathLanguagesMatch() {
        XCTAssertTrue(MathFenceLanguage.matches("math"))
        XCTAssertTrue(MathFenceLanguage.matches("latex"))
        XCTAssertTrue(MathFenceLanguage.matches("tex"))
    }

    func testMatchingIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(MathFenceLanguage.matches("Math"))
        XCTAssertTrue(MathFenceLanguage.matches("  LaTeX  "))
        XCTAssertTrue(MathFenceLanguage.matches("TEX"))
    }

    func testFirstInfoTokenIsUsed() {
        // Markdown info strings can carry extra tokens after the language.
        XCTAssertTrue(MathFenceLanguage.matches("math title=Quadratic"))
    }

    func testNonMathLanguagesDoNotMatch() {
        XCTAssertFalse(MathFenceLanguage.matches("swift"))
        XCTAssertFalse(MathFenceLanguage.matches("python"))
        XCTAssertFalse(MathFenceLanguage.matches("json"))
    }

    func testNilOrEmptyLanguageDoesNotMatch() {
        XCTAssertFalse(MathFenceLanguage.matches(nil))
        XCTAssertFalse(MathFenceLanguage.matches(""))
        XCTAssertFalse(MathFenceLanguage.matches("   "))
    }
}
