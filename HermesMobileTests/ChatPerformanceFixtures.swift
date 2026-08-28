import Foundation
@testable import HermesMobile

enum ChatPerformanceContentKind: String, CaseIterable, Codable {
    case plain
    case markdown
    case code
    case math
    case reasoning
    case tool
}

enum ChatPerformanceToolState: String, CaseIterable, Codable {
    case none
    case collapsed
    case expanded
}

struct ChatPerformanceScenario: Hashable, Codable {
    let rowCount: Int
    let responseBytes: Int
    let contentKind: ChatPerformanceContentKind
    let toolState: ChatPerformanceToolState
    let followsScroll: Bool
    let animationEnabled: Bool

    var id: String {
        [
            "rows-\(rowCount)",
            "response-\(responseBytes)",
            contentKind.rawValue,
            toolState.rawValue,
            followsScroll ? "follow" : "free",
            animationEnabled ? "animated" : "static"
        ].joined(separator: "-")
    }
}

struct ChatPerformanceFixture {
    static let rowCounts = [50, 200, 500]
    static let responseByteLengths = [4_096, 16_384, 65_536]
    static let catalog: [ChatPerformanceScenario] = rowCounts.flatMap { rowCount in
        responseByteLengths.flatMap { responseBytes in
            ChatPerformanceContentKind.allCases.flatMap { contentKind in
                ChatPerformanceToolState.allCases.flatMap { toolState in
                    [false, true].flatMap { followsScroll in
                        [false, true].map { animationEnabled in
                            ChatPerformanceScenario(
                                rowCount: rowCount,
                                responseBytes: responseBytes,
                                contentKind: contentKind,
                                toolState: toolState,
                                followsScroll: followsScroll,
                                animationEnabled: animationEnabled
                            )
                        }
                    }
                }
            }
        }
    }

    let scenario: ChatPerformanceScenario
    let messages: [ChatMessage]
    let response: Data

    static func make(
        rowCount: Int,
        responseBytes: Int,
        contentKind: ChatPerformanceContentKind,
        toolState: ChatPerformanceToolState = .none,
        followsScroll: Bool = true,
        animationEnabled: Bool = false
    ) -> ChatPerformanceFixture {
        precondition(rowCount > 0)
        precondition(responseBytes > 0)
        let scenario = ChatPerformanceScenario(
            rowCount: rowCount,
            responseBytes: responseBytes,
            contentKind: contentKind,
            toolState: toolState,
            followsScroll: followsScroll,
            animationEnabled: animationEnabled
        )
        let messages = (0..<rowCount).map { index in
            ChatMessage(
                role: role(for: index, contentKind: contentKind),
                content: content(for: index, contentKind: contentKind, toolState: toolState),
                timestamp: Double(index),
                messageId: "performance-\(scenario.id)-message-\(index)",
                name: contentKind == .tool ? "read_file" : nil,
                reasoning: contentKind == .reasoning ? "Inspecting deterministic row \(index)." : nil
            )
        }
        let seed = "Hermex deterministic response baseline\n"
        var response = Data(seed.utf8)
        while response.count < responseBytes {
            response.append(contentsOf: Data(seed.utf8))
        }
        response = Data(response.prefix(responseBytes))
        return ChatPerformanceFixture(scenario: scenario, messages: messages, response: response)
    }

    static func hostedPaginationSessionJSON(
        total: Int,
        before: Int?,
        largeAssistantContent: String? = nil
    ) throws -> Data {
        let pageEnd = before ?? total
        let pageStart = max(0, pageEnd - 50)
        let rows = (pageStart..<pageEnd).map { index in
            hostedPaginationRow(
                index: index,
                total: total,
                largeAssistantContent: largeAssistantContent
            )
        }
        let payload: [String: Any] = [
            "session": [
                "session_id": "performance-session",
                "messages": rows,
                "_messages_truncated": pageStart > 0,
                "_messages_offset": pageStart
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func utf8Chunks(from data: Data, maxBytes: Int) -> [String] {
        var chunks: [String] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxBytes, data.count)
            var advanced = false
            while end > offset {
                if let text = String(data: data.subdata(in: offset..<end), encoding: .utf8) {
                    chunks.append(text)
                    offset = end
                    advanced = true
                    break
                }
                end -= 1
            }
            if !advanced {
                offset += 1
            }
        }
        return chunks
    }

    private static func hostedPaginationRow(
        index: Int,
        total: Int,
        largeAssistantContent: String?
    ) -> [String: Any] {
        let isLastAssistant = index == total - 1 && !index.isMultiple(of: 2)
        let content: String
        if isLastAssistant, let largeAssistantContent {
            content = largeAssistantContent
        } else {
            content = self.content(for: index, contentKind: .markdown, toolState: .none)
        }
        return [
            "role": index.isMultiple(of: 2) ? "user" : "assistant",
            "content": content,
            "_ts": Double(index),
            "message_id": "performance-message-\(index)"
        ]
    }

    private static func role(for index: Int, contentKind: ChatPerformanceContentKind) -> String {
        if contentKind == .tool { return "tool" }
        return index.isMultiple(of: 2) ? "user" : "assistant"
    }

    private static func content(
        for index: Int,
        contentKind: ChatPerformanceContentKind,
        toolState: ChatPerformanceToolState
    ) -> String {
        switch contentKind {
        case .plain:
            return "Deterministic plain response row \(index)."
        case .markdown:
            return "## Row \(index)\n\n**Stable** paragraph with `inline code`."
        case .code:
            return "```swift\nlet row = \(index)\n```"
        case .math:
            return "Equation \(index): $x_{\(index)} = \(index + 1)$"
        case .reasoning:
            return "Reasoning row \(index)"
        case .tool:
            let suffix = toolState == .expanded ? " output" : ""
            return "read_file row \(index)\(suffix)"
        }
    }
}

struct CheapChatPerformanceEvidence: Codable {
    let suite: String
    let testName: String
    let commit: String?
    let rowCount: Int
    let responseBytes: Int
    let contentKind: ChatPerformanceContentKind
    let samplesNanoseconds: [UInt64]
    let p50Nanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let p95Definition: String
    let counters: [String: Int]
    let closedIntervals: [String: Int]
    let intervalDurationsNanoseconds: [String: UInt64]
}
