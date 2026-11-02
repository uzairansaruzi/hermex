import Foundation

/// "Describe it": one avatar from the host's model, through `prompt.btw`, which denies every tool
/// at dispatch. A real turn is not safe here: `prompt.submit` runs terminal and file tools with no
/// approval request, a dropped socket does not stop it, and `session.resume` can auto-continue it.
enum BotAvatarGeneration {
    enum Failure: LocalizedError, Equatable {
        case host(String), timedOut, disconnected, unreadable([String])

        var errorDescription: String? {
            switch self {
            case .host(let message):
                return message.isEmpty ? String(localized: "The host could not generate an avatar.") : message
            case .timedOut: return String(localized: "The host took too long to answer.")
            case .disconnected: return String(localized: "The connection dropped before the host answered.")
            case .unreadable(let errors):
                let detail = errors.prefix(3).joined(separator: "\n")
                return String(localized: "The answer was not a usable avatar.") + (detail.isEmpty ? "" : "\n" + detail)
            }
        }
    }

    /// How long to wait for the answer. A slow model took over three minutes on a real host.
    static let answerDeadline: Duration = .seconds(420)

    /// Turns a description into a validated definition, with one repair try on a bad answer.
    nonisolated static func definition(description: String,
                                       send: (String) async throws -> String) async throws -> BotAvatarDefinition {
        let first = try await send(prompt(description: description))
        var errors: [String]
        switch read(first) {
        case .valid(let definition): return definition
        case .invalid(let found): errors = found
        }
        try Task.checkCancellation()
        switch read(try await send(repairPrompt(source: first, errors: errors))) {
        case .valid(let definition): return definition
        case .invalid(let found): errors = found
        }
        throw Failure.unreadable(errors)
    }

    nonisolated static func prompt(description: String) -> String {
        [BotAvatarDesignPrompt.text, "", "---", "", "Create one avatar definition from this description:", "",
         description, "", "Return only the JSON definition, nothing else."].joined(separator: "\n")
    }

    nonisolated static func repairPrompt(source: String, errors: [String]) -> String {
        ([BotAvatarDesignPrompt.text, "", "---", "",
          "This avatar definition failed validation. Fix it while keeping the same character.", "",
          "Validation errors:"] + errors.map { "- \($0)" } + ["", "Definition:", source, "",
          "Return only the corrected JSON definition, nothing else."]).joined(separator: "\n")
    }

    /// Models wrap JSON in prose or code fences, so this reads from the first brace to the last.
    nonisolated static func read(_ answer: String) -> BotAvatarValidator.Validation {
        guard let open = answer.firstIndex(of: "{"), let close = answer.lastIndex(of: "}"), open < close else {
            return .invalid(["the answer contains no JSON object"])
        }
        return BotAvatarValidator.validate(json: Data(answer[open...close].utf8))
    }

    /// One tool-free model call in a hidden draft session under `profile`. The draft is closed and
    /// its empty stored row deleted afterwards, even when the caller stopped waiting, unless the
    /// socket itself has gone. Reads the shared socket's events for its own task only.
    @MainActor static func ask(_ prompt: String, profile: String, transport: any BotTransport,
                               validateDispatch: (() throws -> Void)?) async throws -> String {
        let draft = try await transport.call(.sessionDraft(profile: profile), validateDispatch: validateDispatch)
        guard let runtime = draft["session_id"].text else { throw BotFailure.unsupported }
        let stored = draft["stored_session_id"].text
        let waiter = AnswerWaiter(runtime: runtime)
        let priorEvent = transport.onEvent, priorDisconnect = transport.onDisconnect
        transport.onEvent = { event in priorEvent?(event); waiter.receive(event) }
        transport.onDisconnect = { error in priorDisconnect?(error); waiter.finish(throwing: Failure.disconnected) }
        defer {
            transport.onEvent = priorEvent
            transport.onDisconnect = priorDisconnect
            Task { @MainActor in
                _ = try? await transport.call(.sessionClose(runtime: runtime), validateDispatch: nil)
                if let stored { _ = try? await transport.call(.sessionDelete(profile: profile, storedKey: stored), validateDispatch: nil) }
            }
        }
        let accepted = try await transport.call(.promptBtw(sessionID: runtime, text: prompt), validateDispatch: validateDispatch)
        guard let task = accepted["task_id"].text else { throw BotFailure.unsupported }
        waiter.expect(task)
        return try await waiter.answer(within: answerDeadline)
    }

    /// Holds the one continuation an answer resolves. Everything runs on the main actor, and only
    /// the first of the answer, the deadline, a disconnect or a cancel takes effect.
    @MainActor private final class AnswerWaiter {
        private let runtime: String
        private var taskID: String?
        private var early: [String: String] = [:]
        private var continuation: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?

        init(runtime: String) { self.runtime = runtime }

        func expect(_ task: String) {
            taskID = task
            if let text = early[task] { finish(text) }
        }

        /// `prompt.btw` can answer before its own reply is read, so an early answer is kept.
        func receive(_ event: BotJSON) {
            guard event["type"].text == "btw.complete", event["session_id"].text == runtime,
                  let task = event["payload"]["task_id"].text else { return }
            let text = event["payload"]["text"].text ?? ""
            if let taskID {
                if task == taskID { finish(text) }
            } else {
                early[task] = text
            }
        }

        /// The host reports a failed side question as text starting `error:`.
        private func finish(_ text: String) {
            if text.hasPrefix("error:") {
                finish(throwing: Failure.host(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)))
            } else {
                complete(.success(text))
            }
        }

        func finish(throwing error: Error) { complete(.failure(error)) }

        private func complete(_ outcome: Result<String, Error>) {
            guard result == nil else { return }
            result = outcome
            continuation?.resume(with: outcome)
            continuation = nil
        }

        func answer(within deadline: Duration) async throws -> String {
            let timer = Task { [weak self] in
                guard (try? await Task.sleep(for: deadline)) != nil else { return }
                self?.finish(throwing: Failure.timedOut)
            }
            defer { timer.cancel() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result { continuation.resume(with: result) } else { self.continuation = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(throwing: CancellationError()) }
            }
        }
    }
}
