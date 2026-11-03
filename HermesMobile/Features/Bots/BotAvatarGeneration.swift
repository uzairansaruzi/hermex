import Foundation
import Observation
import SwiftUI

/// "Describe It": one avatar from the host's model, through `prompt.btw`, which denies every tool
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
            case .unreadable: return String(localized: "The answer was not a usable avatar.")
            }
        }
    }

    /// How long to wait for the answer. A slow model can reason for minutes.
    static let answerDeadline: Duration = .seconds(420)
    private static let deleteAttempts = 4
    /// How long a closing draft gets before its row is deleted again. Tests shorten it.
    static var deleteRetryDelay: Duration = .seconds(2)

    /// Adapted from Open Bot Avatar's design prompt (Dominik Scholz, MIT): flat, with a path
    /// grammar the app parses itself, and short enough for a small model to answer quickly.
    static let designPrompt = """
    You design one small flat avatar: a soft, chunky silhouette of an object or creature with two eyes on it. It is shown at about 44 points on a phone. Give geometry only; the app adds the color, the eye shape and the motion.

    Reply with only this JSON on one line, with no prose and no code fence:
    {"name":"Short name","path":"M... Z","eyes":{"x":50,"y":46,"spacing":16,"scale":1.2}}

    Path rules:
    - The canvas is 0 0 100 100 with y pointing down. Keep everything between 8 and 92.
    - Use only the uppercase commands M, L, C, Q and Z, with absolute coordinates and numbers separated by spaces. Close every shape with Z.
    - Use at most 60 segments.
    - The fill rule is nonzero. Draw outlines clockwise on screen, and overlapping outlines merge into one shape. Draw a hole counter-clockwise, only for a real opening such as a handle.
    - The body is at least 40 units on its long side.

    Eye rules:
    - x and y are the center of the pair, and spacing is the distance between the two eye centers.
    - Each eye is a vertical pill 4 x scale wide and 11 x scale tall. Use a scale from 1 to 1.6, and a spacing of at least 10 x scale.
    - Both eyes must sit fully on solid fill with at least 4 units of fill around them, a little above the center of the largest part.

    Design:
    - Make it a simple toy version whose outline alone names the thing. Pick its most iconic view.
    - Make the part that carries the eyes the largest part, about 36 wide and 28 tall.
    - Use a few rounded parts, at least 5 units thick, with curves instead of sharp corners. Avoid thin spikes and small details.
    - Center the mass near x 50, and sit it near y 85.
    - The name is one to three words.

    Check the rules, then answer. Do not narrate your thinking and do not call any tools.
    """

    static func prompt(description: String) -> String { designPrompt + "\n\nDescribe: " + description }

    static func repairPrompt(answer: String, problems: [String]) -> String {
        ([designPrompt, "", "Your last answer failed these checks. Fix them and keep the same character:"]
            + problems.map { "- \($0)" } + ["", "Last answer:", answer]).joined(separator: "\n")
    }

    /// Turns a description into a checked avatar, with one repair try on a bad answer.
    static func avatar(description: String, send: (String) async throws -> String) async throws -> BotGeneratedAvatar {
        let first = try await send(prompt(description: description))
        guard case .failure(.unreadable(let problems)) = BotGeneratedAvatar.read(answer: first) else {
            return try BotGeneratedAvatar.read(answer: first).get()
        }
        try Task.checkCancellation()
        return try BotGeneratedAvatar.read(answer: try await send(repairPrompt(answer: first, problems: problems))).get()
    }

    /// One tool-free model call in a hidden draft session under `profile`. The draft is closed and
    /// its empty stored row deleted afterwards, even when the caller stopped waiting, unless the
    /// socket itself has gone. Reads the shared socket's events for its own task only.
    ///
    /// The calls run in their own task: cancelling a call that isn't cancellation-safe ends the
    /// screen's whole connection, so stopping only stops the waiting. One runs at a time: a call
    /// nobody is waiting for may still hold the socket's handlers until its reply lands, even after
    /// its sheet has closed, so the next starts once it has let them go.
    @MainActor static func ask(_ prompt: String, profile: String, transport: any BotTransport,
                               validateDispatch: (() throws -> Void)?) async throws -> String {
        let waiter = AnswerWaiter()
        let previous = lastCall
        let work = Task { @MainActor in
            await previous?.value
            return try await run(prompt, profile: profile, transport: transport, waiter: waiter, validateDispatch: validateDispatch)
        }
        lastCall = Task { @MainActor in _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            Task { @MainActor in waiter.finish(throwing: CancellationError()) }
        }
    }

    @MainActor private static var lastCall: Task<Void, Never>?

    @MainActor private static func run(_ prompt: String, profile: String, transport: any BotTransport, waiter: AnswerWaiter,
                                       validateDispatch: (() throws -> Void)?) async throws -> String {
        // Stopped while waiting its turn: nothing goes to the host.
        guard !waiter.isFinished else { return try await waiter.answer(within: answerDeadline) }
        let draft = try await transport.call(.sessionDraft(profile: profile), validateDispatch: validateDispatch)
        guard let runtime = draft["session_id"].text else { throw BotFailure.unsupported }
        let stored = draft["stored_session_id"].text
        waiter.runtime = runtime
        let priorEvent = transport.onEvent, priorDisconnect = transport.onDisconnect
        transport.onEvent = { event in priorEvent?(event); waiter.receive(event) }
        transport.onDisconnect = { error in priorDisconnect?(error); waiter.finish(throwing: Failure.disconnected) }
        defer {
            transport.onEvent = priorEvent
            transport.onDisconnect = priorDisconnect
            Task { @MainActor in
                _ = try? await transport.call(.sessionClose(runtime: runtime), validateDispatch: nil)
                guard let stored else { return }
                // The host refuses to delete a session it is still closing, so this tries a few times.
                for attempt in 1...deleteAttempts {
                    if (try? await transport.call(.sessionDelete(profile: profile, storedKey: stored), validateDispatch: nil)) != nil { return }
                    if attempt < deleteAttempts { try? await Task.sleep(for: deleteRetryDelay) }
                }
            }
        }
        // Stopped while the draft was opening: nothing more goes to the host.
        guard !waiter.isFinished else { return try await waiter.answer(within: answerDeadline) }
        let accepted = try await transport.call(.promptBtw(sessionID: runtime, text: prompt), validateDispatch: validateDispatch)
        guard let task = accepted["task_id"].text else { throw BotFailure.unsupported }
        waiter.expect(task)
        return try await waiter.answer(within: answerDeadline)
    }

    /// Holds the one continuation an answer resolves. Everything runs on the main actor, and only
    /// the first of the answer, the deadline, a disconnect or a cancel takes effect.
    @MainActor private final class AnswerWaiter {
        var runtime: String?
        private var taskID: String?
        private var early: [String: String] = [:]
        private var continuation: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?

        var isFinished: Bool { result != nil }

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
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) } else { self.continuation = continuation }
            }
        }
    }
}

/// The sheet's state. The result reaches the editor or creator as a draft, so nothing is on the
/// host until its own Save. Closing stops the waiting, but the host's model call can't be stopped.
@MainActor @Observable final class BotAvatarDescriber {
    enum State: Equatable { case idle, running, failed(String), finished }

    private(set) var state = State.idle
    private let send: (String) async throws -> String
    private let onResult: (BotGeneratedAvatar) -> Void
    private var task: Task<Void, Never>?

    init(send: @escaping (String) async throws -> String, onResult: @escaping (BotGeneratedAvatar) -> Void) {
        self.send = send; self.onResult = onResult
    }

    func generate(description: String) {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, state != .running else { return }
        state = .running
        task = Task { [weak self, send] in
            do {
                let avatar = try await BotAvatarGeneration.avatar(description: description, send: send)
                guard let self, !Task.isCancelled else { return }
                self.onResult(avatar)
                self.state = .finished
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func stopWaiting() {
        task?.cancel()
        if state == .running { state = .idle }
    }
}

/// Describes an avatar for the host's model to draw.
@MainActor struct BotAvatarDescribeSheet: View {
    @State private var describer: BotAvatarDescriber
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(send: @escaping (String) async throws -> String, onResult: @escaping (BotGeneratedAvatar) -> Void) {
        _describer = State(initialValue: BotAvatarDescriber(send: send, onResult: onResult))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("A tiny orange cat holding a wrench", text: $description, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(describer.state == .running)
                if describer.state == .running {
                    Text("Generating. This can take a few minutes.").font(.subheadline)
                    Button("Stop Waiting") { describer.stopWaiting() }.buttonStyle(.bordered)
                } else {
                    Button("Generate") { describer.generate(description: description) }
                        .buttonStyle(.borderedProminent)
                        .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if case .failed(let message) = describer.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("Uses the host's model, with no tools. Your provider may bill for it, even if you stop waiting.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .navigationTitle("Describe It")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .onChange(of: describer.state) { if describer.state == .finished { dismiss() } }
        .onDisappear { describer.stopWaiting() }
        // The editor closes its connection in the background, so no answer can arrive.
        .onChange(of: scenePhase) { if scenePhase == .background { describer.stopWaiting() } }
    }
}

/// Every shape a bot can take, in a compact sideways grid: a generated avatar first when the draft
/// has one, then the classics, then the ready-made avatars. Faces are plain vector drawings, so a
/// tile draws at once.
struct BotAvatarShapePicker: View {
    let name: String
    let appearance: BotProfileAppearance
    let onPick: (BotAvatarShape) -> Void

    private let rows = Array(repeating: GridItem(.fixed(50), spacing: 10), count: 3)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 12) {
                if let generated = appearance.generated {
                    tile(selected: true, name: generated.name) {
                        BotAvatarMarkView(name: name, appearance: appearance, size: 42)
                    }
                }
                ForEach(BotAvatarShape.allCases) { shape in
                    let selected = appearance.generated == nil && appearance.shape == shape.rawValue
                    Button { onPick(shape) } label: {
                        tile(selected: selected, name: shape.localizedName) {
                            BotAvatarMarkView(name: name, appearance: self.appearance(for: shape), size: 42)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shape.localizedName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(16)
        }
    }

    private func tile<Face: View>(selected: Bool, name: String, @ViewBuilder face: () -> Face) -> some View {
        face()
            // Wide enough that the next column peeks in, which shows the grid scrolls.
            .frame(width: 64, height: 50)
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 12).stroke(.secondary, lineWidth: 2) }
            }
            .accessibilityLabel(name)
    }

    private func appearance(for shape: BotAvatarShape) -> BotProfileAppearance {
        var appearance = appearance
        appearance.generated = nil
        appearance.shape = shape.rawValue; appearance.custom = true; appearance.imageKind = "shape"
        return appearance
    }
}
