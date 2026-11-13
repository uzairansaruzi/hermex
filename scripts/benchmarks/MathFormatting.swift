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
        var workloads: [(String, String, (String) -> String)] = [
            ("plain transcript", String(repeating: "A normal response with no math. ", count: 100), layoutText),
            ("inline math transcript", String(repeating: inline, count: 20), layoutText),
            ("protected code and currency", String(repeating: "Code `$x^2$` stays literal. It costs $5 today.\n", count: 20), layoutText),
            ("display math segmentation", String(repeating: "Before $$" + formula + "$$ after.\n", count: 20), layoutText),
            ("nested formula", formula, MarkdownMathFormatter.renderedText),
            ("command replacements", #"\leftarrow \left x \right \Rightarrow \top \to \theta \times \leq \le \neq \ne \varepsilon \epsilon"#, MarkdownMathFormatter.replacingKnownCommands)
        ]
        for count in [64, 128, 256, 512] {
            let partial = String(repeating: #"\[alpha "#, count: count)
            workloads.append(("unclosed display openers \(count)", partial, layoutText))
            workloads.append(("completed display openers \(count)", partial + #"\]"#, layoutText))
        }
        for count in [64, 256, 512] {
            let partial = String(repeating: #"\(alpha "#, count: count)
            workloads.append(("unclosed inline openers \(count)", partial, layoutText))
            workloads.append(("inline recovery after newline \(count)", partial + "\n" + #"\(x^2\)"#, layoutText))
        }
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
        // Long, incrementally delivered content uses the production uncached path.
        // Compare operation counts and checksums as well as isolated medians.
        for (name, paragraph) in [
            ("incremental plain 30KB", "A normal response with ordinary prose.\n\n"),
            ("incremental math 30KB", inline + "\n\n")
        ] {
            let input = String(repeating: paragraph, count: 30_000 / paragraph.utf8.count + 1)
            let prefixes = stride(from: 512, through: input.count, by: 512).map { String(input.prefix($0)) }
            var samples: [Double] = []
            var checksum = 0
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                for prefix in prefixes {
                    checksum &+= layoutText(prefix).utf8.count
                    precondition(!MarkdownMathLayoutCache.hasCachedLayout(for: prefix))
                }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            results.append(["workload": name, "median_ms": samples.sorted()[2],
                            "samples_ms": samples, "updates": prefixes.count, "checksum": checksum])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
