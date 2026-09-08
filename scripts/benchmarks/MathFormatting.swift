import Foundation

/// Timings cover uncached production work, including identical output checks in every run.
@main
struct MathFormattingBenchmark {
    static func layoutText(_ input: String) -> String {
        switch MarkdownMathLayoutCache.uncachedLayout(for: input) {
        case .plain(let text): return text
        case .segmented(let segments):
            return segments.map { segment in
                switch segment {
                case .markdown(let text): return text
                case .displayMath(let latex): return "$$" + latex + "$$"
                }
            }.joined()
        }
    }

    static func main() throws {
        let formula = #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#
        let inline = #"Result: $\alpha + \beta \leq \theta$ and $x^2 + y_0$. "#
        let workloads: [(String, String, (String) -> String)] = [
            ("plain transcript", String(repeating: "A normal response with no math. ", count: 100), layoutText),
            ("inline math transcript", String(repeating: inline, count: 20), layoutText),
            ("protected code and currency", String(repeating: "Code `$x^2$` stays literal. It costs $5 today.\n", count: 20), layoutText),
            ("display math segmentation", String(repeating: "Before $$" + formula + "$$ after.\n", count: 20), layoutText),
            ("nested formula", formula, MarkdownMathFormatter.renderedText),
            ("command replacements", #"\leftarrow \left x \right \Rightarrow \top \to \theta \times \leq \le \neq \ne \varepsilon \epsilon"#, MarkdownMathFormatter.replacingKnownCommands)
        ]
        var results: [[String: Any]] = []
        for (name, input, render) in workloads {
            let expected = render(input)
            var samples: [Double] = []
            var checksum = 0
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<50 {
                    let output = render(input)
                    checksum &+= output.utf8.count
                    precondition(output == expected, "Unstable output for \(name)")
                }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 50)
            }
            results.append([
                "workload": name, "median_ms": samples.sorted()[3],
                "samples_ms": samples, "checksum": checksum, "output": expected
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
