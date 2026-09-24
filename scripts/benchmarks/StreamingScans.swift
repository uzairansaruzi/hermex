import Foundation

/// Per-call timings of the scans a streaming reply pays on every update, at an
/// early and a late point of a code-heavy reply. Flat growth from 5 KB to 30 KB
/// means the cost tracks the reply length linearly, not quadratically.
@main
struct StreamingScansBenchmark {
    static func reply(bytes: Int) -> String {
        let block = """
        ## Step

        Set `$HOME` and export the path, then run the build:

        ```bash
        export PATH="$HOME/bin:$PATH"
        for f in *.swift; do echo "$f"; done
        ```

        - The build writes to `./build` and logs to [the docs](https://example.test).

        """
        var text = ""
        while text.utf8.count < bytes { text += block }
        return String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }

    static func main() throws {
        let workloads: [(String, (String) -> Int)] = [
            ("media parse", { TranscriptMediaParser.segments(in: $0).count }),
            ("media parse, one image", { TranscriptMediaParser.segments(in: "MEDIA:/tmp/shot.png\n" + $0).count }),
            ("block split", { StreamingMarkdownBlockSplitter.split($0).stableChunks.count })
        ]
        var results: [[String: Any]] = []
        for (name, scan) in workloads {
            for size in [5_000, 30_000] {
                let input = reply(bytes: size)
                let expected = scan(input)
                var samples: [Double] = []
                for _ in 0..<7 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<20 {
                        precondition(scan(input) == expected, "Unstable output for \(name)")
                    }
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 20)
                }
                results.append([
                    "workload": name, "bytes": size, "median_ms": samples.sorted()[3], "output": expected
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
