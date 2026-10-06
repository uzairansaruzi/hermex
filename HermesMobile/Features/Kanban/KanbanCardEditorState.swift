import Foundation
import Observation

enum KanbanCardEditorMode: Equatable, Sendable {
    case create
    case edit(cardID: String)
}

enum KanbanCardEditorField: Equatable, Sendable {
    case title
    case priority
    case status
    case workspacePath
    case maximumRuntime
    case prerequisite
}

enum KanbanCardEditorSubmission: Equatable, Sendable {
    case idle
    case validationFailed(KanbanCardEditorField)
    case saving
    case checkingResult
    case conflict
    case succeeded(cardID: String)
    case failed
    case outcomeUncertain

    var isInFlight: Bool {
        self == .saving || self == .checkingResult
    }
}

@MainActor
@Observable
final class KanbanCardEditorState: Identifiable {
    static let workspaceKinds = ["scratch", "worktree", "dir"]

    let id = UUID()

    let mode: KanbanCardEditorMode
    let board: String
    let idempotencyKey: String
    let profileOptions: [String]
    let tenantOptions: [String]
    let prerequisiteOptions: [KanbanCard]

    var title = ""
    var body = ""
    var status = "triage"
    var priorityText = "0"
    var assignee: String?
    var tenant = ""
    /// The workspace kind the user picked, else the Board's default. A Hermes create sends it
    /// unless it is a Scratch nobody picked, which leaves a project Board its project (#1044).
    var workspaceKind: String {
        get { pickedWorkspaceKind ?? defaultWorkspaceKind }
        set { pickedWorkspaceKind = newValue }
    }
    var workspacePath = ""
    var skillsText = ""
    var maximumRuntimeText = ""
    var prerequisiteID = ""

    private(set) var submission: KanbanCardEditorSubmission = .idle
    private(set) var remoteCard: KanbanCard?
    /// Why the server refused the last save, in its own words (`KanbanWriteRefusal`).
    private(set) var failureMessage: String?
    /// The server's note on the created Card, such as a Hermes host's warning that no
    /// dispatcher is running; the Board shows it after the editor closes.
    private(set) var notice: String?

    private let client: any KanbanDataClient
    private let backend: KanbanBackend
    private let defaultWorkspaceKind: String
    private var pickedWorkspaceKind: String?
    private let onCapabilityUnavailable: (KanbanWriteCapability) -> Void
    private var baselineCard: KanbanCard?
    private let baselineMatchingCardIDs: Set<String>
    private var activeAttemptID: UUID?
    private var statusAtOpen = "triage"
    private var remotePrerequisiteID: String?

    private enum MutationIntent {
        case create(KanbanCreateCardRequest)
        case edit(KanbanEditCardRequest)
    }

    init(
        mode: KanbanCardEditorMode,
        board: String,
        client: any KanbanDataClient,
        card: KanbanCard? = nil,
        prerequisiteID: String? = nil,
        defaultWorkspaceKind: String? = nil,
        profileOptions: [String] = [],
        tenantOptions: [String] = [],
        prerequisiteOptions: [KanbanCard] = [],
        baselineCards: [KanbanCard] = [],
        idempotencyKey: String = UUID().uuidString,
        onCapabilityUnavailable: @escaping (KanbanWriteCapability) -> Void = { _ in }
    ) {
        self.mode = mode
        self.board = board
        self.client = client
        backend = client.backend
        // webui's editor starts every Card in Scratch, as before.
        self.defaultWorkspaceKind = client.backend == .hermes
            ? defaultWorkspaceKind.flatMap { Self.workspaceKinds.contains($0) ? $0 : nil } ?? "scratch"
            : "scratch"
        self.profileOptions = profileOptions
        self.tenantOptions = tenantOptions
        self.prerequisiteOptions = prerequisiteOptions
        self.idempotencyKey = idempotencyKey
        self.onCapabilityUnavailable = onCapabilityUnavailable
        baselineCard = card
        baselineMatchingCardIDs = Set(baselineCards.compactMap(\.cardID))
        if let card {
            populate(from: card, prerequisiteID: prerequisiteID)
        }
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var originalStatus: String? {
        baselineCard?.status?.rawValue
    }

    /// The Statuses the Status picker offers: Triage, To Do and Ready, or on a Hermes host
    /// Triage and Ready, which the host turns into To Do while a prerequisite is open (#1044).
    var createStatuses: [String] { backend.createStatuses }

    /// A Hermes host sets a Card's tenant on create only (#1044); webui edits it.
    var canEditTenant: Bool { !isEditing || backend == .webui }

    /// A Hermes host picks a Worktree or Directory Card's path itself, from the Board's project
    /// directory, so it takes none from Hermex (#1044).
    var offersWorkspacePath: Bool { backend == .webui }

    var needsReadyUnassignedConfirmation: Bool {
        !isEditing && status == "ready" && normalized(assignee) == nil
    }

    var canSubmit: Bool {
        !submission.isInFlight && submission != .conflict
    }

    var validationMessage: String? {
        guard case let .validationFailed(field) = submission else { return nil }
        switch field {
        case .title:
            return String(localized: "Title is required.")
        case .priority:
            return String(localized: "Priority must be a whole number from -100 through 100.")
        case .status:
            return String(localized: "Choose a supported Status.")
        case .workspacePath:
            return String(localized: "Workspace path is required for this workspace kind.")
        case .maximumRuntime:
            return String(localized: "Maximum Runtime must be a whole number of seconds greater than 0.")
        case .prerequisite:
            return String(localized: "Choose a valid Prerequisite.")
        }
    }

    func save(allowsMutation: Bool, readyUnassignedConfirmed: Bool = false, overwriteConflict: Bool = false) async {
        guard !submission.isInFlight else { return }
        guard allowsMutation else {
            submission = .failed
            return
        }
        guard validate() else { return }
        if needsReadyUnassignedConfirmation && !readyUnassignedConfirmed {
            return
        }

        let attemptID = UUID()
        activeAttemptID = attemptID
        failureMessage = nil
        submission = .saving

        if case let .edit(cardID) = mode, !overwriteConflict {
            do {
                let detail = try await client.kanbanCardDetail(
                    KanbanCardDetailRequest(cardID: cardID, board: board)
                )
                try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
                guard isCurrent(attemptID), let latest = detail.card else { return }
                if hasRemoteChange(latest) {
                    remoteCard = latest
                    remotePrerequisiteID = detail.links?.prerequisites?.first
                    submission = .conflict
                    activeAttemptID = nil
                    return
                }
            } catch {
                guard isCurrent(attemptID) else { return }
                // No mutation has been attempted, so this is a read failure,
                // never an uncertain write outcome.
                submission = .failed
                activeAttemptID = nil
                return
            }
        }

        // The preflight suspends. Revalidate after it returns, then capture an
        // immutable mutation intent used for both the write and reconciliation.
        guard validate() else {
            activeAttemptID = nil
            return
        }
        if needsReadyUnassignedConfirmation && !readyUnassignedConfirmed {
            submission = .idle
            activeAttemptID = nil
            return
        }
        let intent: MutationIntent
        switch mode {
        case .create:
            intent = .create(createRequest())
        case let .edit(cardID):
            intent = .edit(editRequest(cardID: cardID))
        }
        submission = .saving
        do {
            let envelope: KanbanCardMutationEnvelope
            switch intent {
            case let .create(request):
                envelope = try await client.createKanbanCard(request)
            case let .edit(request):
                envelope = try await client.editKanbanCard(request)
            }
            guard isCurrent(attemptID) else { return }
            let card = try KanbanCardMutationValidator.validate(
                envelope,
                expectedCardID: editedCardID
            )
            guard intendedValuesAppear(in: card, intent: intent) else {
                throw KanbanContractViolation.missingCardStatus
            }
            notice = envelope.warning
            complete(with: card, attemptID: attemptID)
        } catch {
            guard isCurrent(attemptID) else { return }
            if KanbanEndpointCompatibility.isMissingCapability(error) {
                onCapabilityUnavailable(isEditing ? .editCard : .createCard)
            }
            if isDefinitiveWriteFailure(error) {
                failureMessage = KanbanWriteRefusal.message(for: error)
                submission = .failed
                activeAttemptID = nil
            } else {
                await reconcileAmbiguousOutcome(intent: intent, attemptID: attemptID)
            }
        }
    }

    func reloadServerVersion() {
        guard let remoteCard else { return }
        populate(from: remoteCard, prerequisiteID: remotePrerequisiteID)
        baselineCard = remoteCard
        self.remoteCard = nil
        remotePrerequisiteID = nil
        submission = .idle
    }

    func dismissError() {
        guard !submission.isInFlight else { return }
        submission = .idle
    }

    private var editedCardID: String? {
        guard case let .edit(cardID) = mode else { return nil }
        return cardID
    }

    private func validate() -> Bool {
        if normalized(title) == nil {
            submission = .validationFailed(.title)
            return false
        }
        guard let priority = Int(priorityText), (-100...100).contains(priority) else {
            submission = .validationFailed(.priority)
            return false
        }
        guard createStatuses.contains(status) || (isEditing && status == statusAtOpen) else {
            submission = .validationFailed(.status)
            return false
        }
        if !isEditing {
            guard Self.workspaceKinds.contains(workspaceKind) else {
                submission = .validationFailed(.workspacePath)
                return false
            }
            if offersWorkspacePath, workspaceKind != "scratch", normalized(workspacePath) == nil {
                submission = .validationFailed(.workspacePath)
                return false
            }
            if !maximumRuntimeText.isEmpty,
               Int(maximumRuntimeText).map({ $0 > 0 }) != true {
                submission = .validationFailed(.maximumRuntime)
                return false
            }
            if prerequisiteID.count > 255 {
                submission = .validationFailed(.prerequisite)
                return false
            }
        }
        return true
    }

    private func createRequest() -> KanbanCreateCardRequest {
        KanbanCreateCardRequest(
            board: board,
            title: normalized(title)!,
            body: normalized(body) == nil ? nil : body,
            status: status,
            priority: Int(priorityText) == 0 ? nil : Int(priorityText),
            assignee: normalized(assignee),
            tenant: normalized(tenant),
            workspaceKind: backend == .hermes && pickedWorkspaceKind == nil && workspaceKind == "scratch"
                ? nil : workspaceKind,
            workspacePath: offersWorkspacePath ? normalized(workspacePath) : nil,
            skills: parsedSkills,
            maxRuntimeSeconds: Int(maximumRuntimeText),
            prerequisiteID: normalized(prerequisiteID),
            idempotencyKey: idempotencyKey
        )
    }

    private func editRequest(cardID: String) -> KanbanEditCardRequest {
        return KanbanEditCardRequest(
            cardID: cardID,
            board: board,
            title: normalized(title)!,
            body: body,
            tenant: normalized(tenant),
            priority: Int(priorityText)!,
            assignee: normalized(assignee),
            status: status == statusAtOpen ? nil : status,
            changesAssignee: normalized(assignee) != normalized((remoteCard ?? baselineCard)?.assignee)
        )
    }

    private var parsedSkills: [String]? {
        let values = skillsText
            .split(separator: ",")
            .compactMap { normalized(String($0)) }
        return values.isEmpty ? nil : values
    }

    private func reconcileAmbiguousOutcome(intent: MutationIntent, attemptID: UUID) async {
        submission = .checkingResult
        do {
            switch mode {
            case .create:
                let snapshot = try await client.kanbanBoard(KanbanBoardRequest(board: board))
                guard isCurrent(attemptID) else { return }
                let matches = (snapshot.columns ?? [])
                    .flatMap { $0.cards ?? [] }
                    .filter { card in
                        guard let id = card.cardID, !baselineMatchingCardIDs.contains(id) else { return false }
                        return intendedValuesAppear(in: card, intent: intent)
                    }
                if matches.count == 1, let card = matches.first {
                    complete(with: card, attemptID: attemptID)
                } else if matches.isEmpty {
                    submission = .failed
                    activeAttemptID = nil
                } else {
                    submission = .outcomeUncertain
                    activeAttemptID = nil
                }
            case let .edit(cardID):
                let detail = try await client.kanbanCardDetail(
                    KanbanCardDetailRequest(cardID: cardID, board: board)
                )
                try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
                guard isCurrent(attemptID), let card = detail.card else { return }
                if intendedValuesAppear(in: card, intent: intent) {
                    complete(with: card, attemptID: attemptID)
                } else {
                    remoteCard = card
                    remotePrerequisiteID = detail.links?.prerequisites?.first
                    submission = .failed
                    activeAttemptID = nil
                }
            }
        } catch {
            guard isCurrent(attemptID) else { return }
            submission = .outcomeUncertain
            activeAttemptID = nil
        }
    }

    private func complete(with card: KanbanCard, attemptID: UUID) {
        guard isCurrent(attemptID), let cardID = normalized(card.cardID) else { return }
        baselineCard = card
        remoteCard = nil
        remotePrerequisiteID = nil
        submission = .succeeded(cardID: cardID)
        activeAttemptID = nil
    }

    /// Whether `card` carries what the save asked for. A Hermes host decides what the save
    /// leaves to it (#1044): a new Card's tenant (a prerequisite's) and workspace kind (Scratch
    /// or the project's worktree) when none was sent, and To Do for a Card asked into Ready.
    private func intendedValuesAppear(in card: KanbanCard, intent: MutationIntent) -> Bool {
        switch intent {
        case let .create(request):
            let hostDecides = backend == .hermes
            return normalized(card.title) == normalized(request.title)
                && normalized(card.body) == normalized(request.body)
                && normalized(card.assignee) == normalized(request.assignee)
                && (normalized(card.tenant) == normalized(request.tenant) || (hostDecides && request.tenant == nil))
                && (card.priority ?? 0) == (request.priority ?? 0)
                && backend.accepts(card.status?.rawValue, requested: request.status, from: nil)
                && (normalized(card.workspaceKind) == normalized(request.workspaceKind)
                    || (hostDecides && request.workspaceKind == nil))
                && normalized(card.workspacePath) == normalized(request.workspacePath)
                && (card.skills ?? []) == (request.skills ?? [])
                && card.maxRuntimeSeconds == request.maxRuntimeSeconds
        case let .edit(request):
            return normalized(card.title) == normalized(request.title)
                && normalized(card.body) == normalized(request.body)
                && normalized(card.assignee) == normalized(request.assignee)
                && normalized(card.tenant) == normalized(request.tenant)
                && (card.priority ?? 0) == request.priority
                && (request.status.map { backend.accepts(card.status?.rawValue, requested: $0, from: statusAtOpen) } ?? true)
        }
    }

    private func hasRemoteChange(_ card: KanbanCard) -> Bool {
        guard let baselineCard else { return true }
        return fingerprint(card) != fingerprint(baselineCard)
    }

    private func fingerprint(_ card: KanbanCard) -> [String] {
        [
            normalized(card.title) ?? "",
            normalized(card.body) ?? "",
            normalized(card.assignee) ?? "",
            normalized(card.tenant) ?? "",
            String(card.priority ?? 0),
            normalized(card.status?.rawValue) ?? "",
            normalized(card.workspaceKind) ?? "",
            normalized(card.workspacePath) ?? "",
            (card.skills ?? []).joined(separator: "\u{1F}"),
            card.maxRuntimeSeconds.map(String.init) ?? ""
        ]
    }

    private func populate(from card: KanbanCard, prerequisiteID: String?) {
        title = card.title ?? ""
        body = card.body ?? ""
        status = card.status?.rawValue ?? "triage"
        statusAtOpen = status
        priorityText = String(card.priority ?? 0)
        assignee = normalized(card.assignee)
        tenant = card.tenant ?? ""
        workspaceKind = Self.workspaceKinds.contains(card.workspaceKind ?? "") ? card.workspaceKind! : "scratch"
        workspacePath = card.workspacePath ?? ""
        skillsText = (card.skills ?? []).joined(separator: ", ")
        maximumRuntimeText = card.maxRuntimeSeconds.map(String.init) ?? ""
        self.prerequisiteID = prerequisiteID ?? ""
    }

    private func isCurrent(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    private func isDefinitiveWriteFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return error is KanbanWriteRefusal }
        switch apiError {
        case .unauthorized, .invalidServerURL:
            return true
        case let .http(statusCode, _):
            return (400..<500).contains(statusCode) && statusCode != 408
        case .network, .decoding:
            return false
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
