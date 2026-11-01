import Foundation

/// An answered `clarify` tool call read as question and answer pairs, so the
/// transcript shows what the user told the agent instead of raw JSON.
///
/// Reads the two shapes `tools/clarify_tool.py` returns (hermes-agent at
/// `HERMES_AGENT_TESTED_SHA`): a batch `{"responses": [{question,
/// user_response, …}], "timed_out"?: true, "notice"?: "…"}` and the legacy
/// single `{question, choices_offered, user_response}`. Anything else, an error
/// envelope, or an answer of an unknown type is `nil`, and the call keeps its
/// generic tool row.
struct ClarifyResult: Equatable {
    struct Exchange: Equatable {
        let question: String
        /// One entry for a typed or single-choice answer, several for a
        /// multi-select; empty when the user skipped it or the wait ended.
        let answers: [String]

        /// The answer as one line ("Lint, Unit tests"), or nil when unanswered.
        var answerText: String? {
            answers.isEmpty ? nil : answers.formatted(.list(type: .and, width: .narrow))
        }

        /// "Question: …. Answer: …", for VoiceOver and the copied text. A
        /// question that ends in its own mark ("Ship it?") gets no extra period.
        var spokenText: String {
            let answer = answerText ?? String(localized: "No answer")
            if let last = question.last, ".?!…。？！؟۔".contains(last) {
                return String(localized: "Question: \(question) Answer: \(answer)")
            }
            return String(localized: "Question: \(question). Answer: \(answer)")
        }
    }

    /// One exchange as its own transcript line, keyed by the call and the
    /// exchange's position so a folded turn shows each answer once.
    struct Line: Identifiable, Equatable {
        let id: String
        let exchange: Exchange
        /// Why the wait ended, on the result's last exchange only.
        let note: String?
    }

    let exchanges: [Exchange]
    /// The wait ended before every question was answered.
    let timedOut: Bool
    /// The server's reason the wait ended, sent only beside `timedOut`.
    let notice: String?

    /// The exact text the legacy single-question path returns as the answer
    /// when the user never responds (`TIMEOUT_RESPONSE`).
    static let legacyTimeoutResponse = "The user did not provide a response within the time limit. "
        + "Use your best judgement to make the choice and proceed."

    /// The recognized result of a `clarify` call, or nil for any other tool.
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

    /// What the transcript says about how the wait ended: the server's notice,
    /// a plain timeout line when it sent none, or nil when nothing timed out.
    var note: String? {
        guard timedOut else { return nil }
        return notice ?? String(localized: "Timed out waiting for an answer.")
    }

    /// Each exchange as a line keyed under `toolCallID`, the note on the last.
    func lines(toolCallID: String) -> [Line] {
        exchanges.enumerated().map { index, exchange in
            Line(
                id: "\(toolCallID)#\(index)",
                exchange: exchange,
                note: index == exchanges.count - 1 ? note : nil
            )
        }
    }

    /// The answered questions of every recognized `clarify` call in `groups`,
    /// in call order. A folded turn draws these in place of its tool rows.
    static func lines(in groups: [ToolCallGroup]) -> [Line] {
        groups.flatMap(\.toolCalls).flatMap { toolCall in
            ClarifyResult(toolCall: toolCall)?.lines(toolCallID: toolCall.presentationID) ?? []
        }
    }

    /// `user_response` as answers: a string or an array of strings, blanks
    /// dropped. Nil for a missing or unknown type, which is not evidence the
    /// user skipped the question.
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
