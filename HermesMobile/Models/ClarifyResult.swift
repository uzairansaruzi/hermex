import Foundation

struct ClarifyResult: Equatable {
    struct Exchange: Equatable {
        let question: String
        let answers: [String]

        var answerText: String? {
            answers.isEmpty ? nil : answers.formatted(.list(type: .and, width: .narrow))
        }

        var spokenText: String {
            let answer = answerText ?? String(localized: "No answer")
            if let last = question.last, ".?!…。？！؟۔".contains(last) {
                return String(localized: "Question: \(question) Answer: \(answer)")
            }
            return String(localized: "Question: \(question). Answer: \(answer)")
        }
    }

    struct Line: Identifiable, Equatable {
        let id: String
        let exchange: Exchange
        let note: String?
    }

    let exchanges: [Exchange]
    let timedOut: Bool
    let notice: String?

    static let legacyTimeoutResponse = "The user did not provide a response within the time limit. "
        + "Use your best judgement to make the choice and proceed."

    init?(toolCall: ToolCall) {
        guard toolCall.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clarify",
              let preview = toolCall.preview
        else {
            return nil
        }
        self.init(preview: preview)
    }

    init?(preview: String) {
        guard case .object(let object)? = ToolCallDisplayFormatter.parsedJSONValue(from: preview),
              object["error"] == nil || object["error"] == .null
        else {
            return nil
        }

        let entries: [[String: JSONValue]]
        if case .array(let responses)? = object["responses"] {
            var objects: [[String: JSONValue]] = []
            for response in responses {
                guard case .object(let entry) = response else { return nil }
                objects.append(entry)
            }
            entries = objects
        } else {
            entries = [object]
        }

        var exchanges: [Exchange] = []
        var timedOut = object["timed_out"] == .bool(true)
        for entry in entries {
            guard case .string(let rawQuestion)? = entry["question"],
                  let question = Self.nonEmpty(rawQuestion),
                  let answers = Self.answers(from: entry["user_response"])
            else {
                return nil
            }
            if answers == [Self.legacyTimeoutResponse] {
                timedOut = true
                exchanges.append(Exchange(question: question, answers: []))
            } else {
                exchanges.append(Exchange(question: question, answers: answers))
            }
        }
        guard !exchanges.isEmpty else { return nil }

        self.exchanges = exchanges
        self.timedOut = timedOut
        if case .string(let notice)? = object["notice"] {
            self.notice = Self.nonEmpty(notice)
        } else {
            self.notice = nil
        }
    }

    var note: String? {
        guard timedOut else { return nil }
        return notice ?? String(localized: "Timed out waiting for an answer.")
    }

    func lines(toolCallID: String) -> [Line] {
        exchanges.enumerated().map { index, exchange in
            Line(
                id: "\(toolCallID)#\(index)",
                exchange: exchange,
                note: index == exchanges.count - 1 ? note : nil
            )
        }
    }

    static func lines(in groups: [ToolCallGroup]) -> [Line] {
        groups.flatMap(\.toolCalls).flatMap { toolCall in
            ClarifyResult(toolCall: toolCall)?.lines(toolCallID: toolCall.presentationID) ?? []
        }
    }

    private static func answers(from value: JSONValue?) -> [String]? {
        switch value {
        case .string(let answer)?:
            return nonEmpty(answer).map { [$0] } ?? []
        case .array(let items)?:
            var answers: [String] = []
            for item in items {
                guard case .string(let answer) = item else { return nil }
                if let answer = nonEmpty(answer) { answers.append(answer) }
            }
            return answers
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
