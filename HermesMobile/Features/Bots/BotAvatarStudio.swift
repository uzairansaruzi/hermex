import Foundation
import Observation
import SwiftUI

/// The Avatar studio's working copy of a bot's face. It edits a copy of the appearance and
/// hands it back on Done, so Cancel is a clean undo and nothing reaches the host until the
/// editor's or creator's own Save. Every definition it holds has passed the validator.
@MainActor @Observable final class BotAvatarStudio {
    enum Tool: String, CaseIterable, Identifiable {
        case avatar, style, eyes, create
        var id: String { rawValue }
    }
    enum Generation: Equatable { case idle, running, failed(String) }

    /// The Profile name that seeds the face's motion and default look.
    let name: String
    private(set) var appearance: BotProfileAppearance
    private(set) var cue: BotFaceCue?
    private(set) var generation = Generation.idle
    /// The validator's errors for the last import, in its own words.
    private(set) var importErrors: [String] = []
    var tool = Tool.avatar

    let canGenerate: Bool
    private let initial: BotProfileAppearance
    private let hadPhoto: Bool
    /// The placement Reset Eyes returns to and expression tiles draw, so a drag never rebuilds them.
    private(set) var baseEyes: BotAvatarDefinition.Eyes?
    private let sendPrompt: ((String) async throws -> String)?
    private var generationTask: Task<Void, Never>?
    /// Bumped by anything that replaces the body, so a check still running can't overwrite it.
    private var eyeGeneration = 0
    private var pendingEyes: BotAvatarDefinition.Eyes?
    private var eyeWorker: Task<Void, Never>?
    /// The most often a drag rebuilds the face.
    private static let eyeInterval: Duration = .milliseconds(150)

    /// `sendPrompt` runs one tool-free model call on the host and returns its text; nil when
    /// nothing is connected to ask.
    init(name: String, appearance: BotProfileAppearance, hadPhoto: Bool,
         sendPrompt: ((String) async throws -> String)?) {
        self.name = name; self.appearance = appearance; initial = appearance; self.hadPhoto = hadPhoto
        baseEyes = appearance.drawn?.definition.eyes
        self.sendPrompt = sendPrompt; canGenerate = sendPrompt != nil
    }

    var hasChanges: Bool { appearance != initial }
    /// Done must warn: the body changed on a bot with a photo. An expression alone leaves the photo.
    var replacesPhoto: Bool { hadPhoto && bodyChanged }
    /// Whether the host's photo should be cleared on Save.
    var bodyChanged: Bool {
        appearance.drawn != initial.drawn || appearance.shape != initial.shape
            || appearance.color != initial.color || appearance.custom != initial.custom
    }

    private var presentation: BotAvatarPresentation { BotAvatarPresentation(name: name, appearance: appearance) }

    /// The shape this face shows, stored or name-seeded.
    var currentShape: BotAvatarShape {
        appearance.drawn.flatMap { BotAvatarClassic.shape(of: $0.definition) } ?? presentation.shape
    }
    var isClassicFace: Bool { appearance.drawn.map { BotAvatarClassic.isClassic($0.definition) } ?? true }
    /// A plain name for what is picked, for Edit Bot's row.
    var summary: String { Self.summary(of: appearance, name: name) }

    static func summary(of appearance: BotProfileAppearance, name: String) -> String {
        if let drawn = appearance.drawn, !BotAvatarClassic.isClassic(drawn.definition) {
            return BotAvatarCatalog.localizedName(of: drawn.definition)
        }
        let shape = appearance.drawn.flatMap { BotAvatarClassic.shape(of: $0.definition) }
            ?? BotAvatarPresentation(name: name, appearance: appearance).shape
        return shape.localizedName
    }

    // MARK: Avatar

    func pick(_ shape: BotAvatarShape) {
        appearance.shape = shape.rawValue
        markCustom()
        let keeps = appearance.drawn?.eyeColor
        appearance.drawn = keeps == nil ? nil : BotDrawnAvatar(definition: BotAvatarClassic.definition(shape), depth: 0, eyeColor: keeps)
        replacedBody(eyes: BotAvatarClassic.definition(shape).eyes)
        cue = BotFaceCue(.hop)
    }

    /// Takes the avatar's own color too, since that is what the tile showed.
    func pick(_ entry: BotAvatarCatalog.Entry) {
        appearance.drawn = BotDrawnAvatar(definition: entry.definition, depth: BotDrawnAvatar.naturalDepth,
                                          eyeColor: appearance.drawn?.eyeColor)
        appearance.color = entry.color
        markCustom()
        replacedBody(eyes: entry.definition.eyes)
        cue = BotFaceCue(.hop)
    }

    func isPicked(_ shape: BotAvatarShape) -> Bool { isClassicFace && currentShape == shape }
    func isPicked(_ entry: BotAvatarCatalog.Entry) -> Bool { appearance.drawn?.definition.id == entry.definition.id }

    // MARK: Style

    func setBodyColor(_ hex: String) {
        appearance.color = hex.lowercased()
        markCustom()
    }

    /// Nil returns the eyes to contrasting with the body on their own.
    func setEyeColor(_ hex: String?) {
        guard hex != nil || appearance.drawn != nil else { return }
        var drawn = drawnForEditing()
        drawn.eyeColor = hex?.lowercased()
        store(drawn)
    }

    var depth: Int { appearance.drawn?.depth ?? 0 }

    func setDepth(_ value: Int) {
        guard value != depth else { return }
        var drawn = drawnForEditing()
        drawn.depth = min(max(value, BotDrawnAvatar.depthRange.lowerBound), BotDrawnAvatar.depthRange.upperBound)
        store(drawn)
    }

    // MARK: Eyes

    func setExpression(_ expression: BotAvatarExpression) {
        appearance.expression = expression == .neutral ? nil : expression.rawValue
    }

    /// The eyes as sliders and drags read them. A classic face with no drawn avatar reports the
    /// placement it would take on.
    var eyes: BotAvatarDefinition.Eyes {
        appearance.drawn?.definition.eyes ?? BotAvatarClassic.definition(currentShape).eyes
    }

    /// Takes new eyes only if they pass the validator, checked off the main thread, so a drag past
    /// the body's edge simply stops at the last place that fit. One worker runs at a time and takes
    /// only the latest proposal, so a fast drag can't queue up rebuilds of the face.
    @discardableResult func propose(eyes proposed: BotAvatarDefinition.Eyes) -> Task<Void, Never> {
        pendingEyes = proposed
        if let eyeWorker { return eyeWorker }
        let worker = Task { [weak self] in
            while let self, let next = self.pendingEyes {
                self.pendingEyes = nil
                await self.apply(eyes: next)
                try? await Task.sleep(for: Self.eyeInterval)
            }
            self?.eyeWorker = nil
        }
        eyeWorker = worker
        return worker
    }

    private func apply(eyes: BotAvatarDefinition.Eyes) async {
        var definition = appearance.drawn?.definition ?? BotAvatarClassic.definition(currentShape)
        definition.eyes = eyes
        let generation = eyeGeneration, candidate = definition
        let valid = await Task.detached(priority: .userInitiated) { () -> Bool in
            if case .valid = BotAvatarValidator.validate(candidate) { return true }
            return false
        }.value
        guard valid, generation == eyeGeneration else { return }
        var drawn = drawnForEditing()
        drawn.definition.eyes = eyes
        store(drawn)
    }

    /// Back to where this body's eyes started: its ready-made or classic placement, or for an
    /// imported avatar where they were when it arrived.
    func resetEyes() {
        guard var drawn = appearance.drawn, let baseEyes else { return }
        pendingEyes = nil
        eyeGeneration += 1
        drawn.definition.eyes = baseEyes
        store(drawn)
    }

    private func replacedBody(eyes: BotAvatarDefinition.Eyes) {
        pendingEyes = nil
        eyeGeneration += 1
        baseEyes = eyes
    }

    // MARK: Reset

    /// Returns to the name-seeded classic face.
    func reset() {
        replacedBody(eyes: BotAvatarClassic.definition(BotAvatarPresentation(name: name, appearance: appearance.withoutDrawnAvatar).shape).eyes)
        appearance.drawn = nil; appearance.shape = nil; appearance.color = nil
        appearance.expression = nil; appearance.custom = false; appearance.imageKind = nil
    }

    // MARK: Create

    /// What Export shares: the definition alone, in the format Import and the upstream editor read.
    var exportText: String {
        let definition = appearance.drawn?.definition ?? BotAvatarClassic.definition(currentShape)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(definition)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func importDefinition(_ data: Data) async -> Bool {
        switch await Self.validate(data) {
        case .valid(let definition):
            adopt(definition)
            return true
        case .invalid(let errors):
            importErrors = errors
            return false
        }
    }

    func noteImportFailure(_ message: String) { importErrors = [message] }
    func clearImportErrors() { importErrors = [] }

    /// Asks the host for an avatar. The answer is a draft like any other pick. Closing the studio
    /// stops waiting, but the host's model call cannot be stopped.
    func generate(description: String) {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sendPrompt, !description.isEmpty, generation != .running else { return }
        generation = .running
        generationTask = Task { [weak self] in
            do {
                let definition = try await BotAvatarGeneration.definition(description: description, send: sendPrompt)
                guard let self, !Task.isCancelled else { return }
                self.adopt(definition)
                self.generation = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func stopWaiting() {
        generationTask?.cancel()
        generationTask = nil
        if generation == .running { generation = .idle }
    }

    private func adopt(_ definition: BotAvatarDefinition) {
        appearance.drawn = BotDrawnAvatar(definition: definition, depth: BotDrawnAvatar.naturalDepth,
                                          eyeColor: appearance.drawn?.eyeColor)
        markCustom()
        replacedBody(eyes: definition.eyes)
        importErrors = []
        tool = .avatar
        cue = BotFaceCue(.hop)
    }

    private nonisolated static func validate(_ data: Data) async -> BotAvatarValidator.Validation {
        await Task.detached(priority: .userInitiated) { BotAvatarValidator.validate(json: data) }.value
    }

    private func markCustom() {
        if appearance.shape == nil { appearance.shape = presentation.shape.rawValue }
        appearance.custom = true
        appearance.imageKind = "shape"
    }

    /// The drawn avatar to change. A flat classic face has none yet, so it takes on its own
    /// shape's definition, pinning the shape and color it was showing.
    private func drawnForEditing() -> BotDrawnAvatar {
        if let drawn = appearance.drawn { return drawn }
        let shape = currentShape, hex = presentation.hex
        baseEyes = BotAvatarClassic.definition(shape).eyes
        appearance.shape = shape.rawValue
        appearance.color = hex
        return BotDrawnAvatar(definition: BotAvatarClassic.definition(shape), depth: 0)
    }

    /// Stores an edit. A classic shape back at its plain settings drops the drawn avatar, so the
    /// bot goes back to its exact flat look and stores nothing extra.
    private func store(_ drawn: BotDrawnAvatar) {
        markCustom()
        if let shape = BotAvatarClassic.shape(of: drawn.definition), drawn.depth == 0, drawn.eyeColor == nil,
           drawn.definition.eyes == BotAvatarClassic.definition(shape).eyes {
            appearance.drawn = nil
        } else {
            appearance.drawn = drawn
        }
    }
}

extension BotProfileAppearance {
    /// Takes the face a studio ended with, keeping this appearance's own title.
    mutating func adoptFace(of other: BotProfileAppearance) {
        let title = title
        self = other
        self.title = title
    }
}

extension BotAvatarCatalog {
    /// The two rows the Avatar tool shows the ready-made avatars in.
    private static let creatureIDs: Set<String> = ["cat", "ghost", "bunny", "bull", "brain", "star", "cloud"]
    static var creatures: [Entry] { entries.filter { creatureIDs.contains($0.definition.id) } }
    static var objects: [Entry] { entries.filter { !creatureIDs.contains($0.definition.id) } }

    /// A ready-made avatar's translated name; an imported or generated one keeps its own.
    static func localizedName(of definition: BotAvatarDefinition) -> String {
        switch definition.id {
        case "book": return String(localized: "Book")
        case "brain": return String(localized: "Brain")
        case "bull": return String(localized: "Bull")
        case "bunny": return String(localized: "Bunny")
        case "camera": return String(localized: "Camera")
        case "cat": return String(localized: "Cat")
        case "cloud": return String(localized: "Cloud")
        case "ghost": return String(localized: "Ghost")
        case "magnifier": return String(localized: "Magnifier")
        case "paint-brush": return String(localized: "Paint Brush")
        case "palette": return String(localized: "Palette")
        case "rocket": return String(localized: "Rocket")
        case "shield": return String(localized: "Shield")
        case "star": return String(localized: "Star")
        case "witch-hat": return String(localized: "Witch Hat")
        case "controller": return String(localized: "Controller")
        case "barbell": return String(localized: "Barbell")
        case "mug": return String(localized: "Mug")
        case "lightbulb": return String(localized: "Lightbulb")
        case "chat": return String(localized: "Chat Bubble")
        case "sprout": return String(localized: "Sprout")
        case "watering-can": return String(localized: "Watering Can")
        default: return definition.name
        }
    }
}
