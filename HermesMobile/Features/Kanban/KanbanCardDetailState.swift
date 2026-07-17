import Foundation
import Observation

enum KanbanCardDetailLoadState: Equatable {
    case idle
    case loading
    case loaded
    case missingCard
    case missingBoard
    case failed
}

enum KanbanCommentSubmissionState: Equatable {
    case idle
    case validationFailed
    case submitting
    case checkingResult
    case succeeded
    case failed
    case outcomeUncertain

    var isInFlight: Bool {
        self == .submitting || self == .checkingResult
    }
}

enum KanbanWorkerLogState: Equatable {
    case idle
    case loading
    case absent
    case loaded(KanbanWorkerLog)
    case failed
}

@MainActor
@Observable
final class KanbanCardDetailState {
    let cardID: String
    let board: String

    private(set) var loadState: KanbanCardDetailLoadState = .idle
    private(set) var detail: KanbanCardDetailEnvelope?
    private(set) var commentSubmission: KanbanCommentSubmissionState = .idle
    private(set) var workerLogState: KanbanWorkerLogState = .idle
    var commentDraft = ""

    private let client: any KanbanDataClient
    private let onAPIError: (Error) -> Void
    private let onDetailLoaded: (KanbanCardDetailEnvelope) -> Void
    private var activeDetailLoadID: UUID?
    private var activeMutationID: UUID?
    private var lastReconciledRevision = -1
    private var pendingAttempt: PendingCommentAttempt?

    init(
        cardID: String,
        board: String,
        client: any KanbanDataClient,
        onAPIError: @escaping (Error) -> Void = { _ in },
        onDetailLoaded: @escaping (KanbanCardDetailEnvelope) -> Void = { _ in }
    ) {
        self.cardID = cardID
        self.board = board
        self.client = client
        self.onAPIError = onAPIError
        self.onDetailLoaded = onDetailLoaded
    }

    var canSubmitDraft: Bool {
        !normalized(commentDraft).isEmpty && !commentSubmission.isInFlight
    }

    func load() async {
        guard loadState == .idle else { return }
        await fetchDetail(showsLoadingState: true)
    }

    func refresh() async {
        if commentSubmission == .outcomeUncertain, pendingAttempt != nil {
            await checkPendingCommentOutcome()
        } else {
            await fetchDetail(showsLoadingState: detail == nil)
        }
    }

    func reconcile(revision: Int) async {
        guard revision > lastReconciledRevision else { return }
        lastReconciledRevision = revision
        guard loadState == .loaded, !commentSubmission.isInFlight else { return }
        await fetchDetail(showsLoadingState: false)
    }

    func submitComment(allowsMutation: Bool) async {
        guard allowsMutation, !commentSubmission.isInFlight else { return }
        let body = normalized(commentDraft)
        guard !body.isEmpty else {
            commentSubmission = .validationFailed
            return
        }

        let mutationID = UUID()
        activeMutationID = mutationID
        activeDetailLoadID = UUID() // Invalidates a read that began before this mutation.
        let attempt = PendingCommentAttempt(body: body, baseline: detail?.comments ?? [])
        pendingAttempt = attempt
        commentSubmission = .submitting

        do {
            let response = try await client.addKanbanComment(
                KanbanAddCommentRequest(cardID: cardID, board: board, body: body)
            )
            guard !Task.isCancelled, activeMutationID == mutationID else { return }
            guard response.ok == true else {
                commentSubmission = .checkingResult
                await checkPendingCommentOutcome(mutationID: mutationID)
                return
            }

            commentDraft = ""
            commentSubmission = .succeeded
            pendingAttempt = nil
            activeMutationID = nil
            await fetchDetail(showsLoadingState: false)
        } catch {
            guard activeMutationID == mutationID else { return }
            guard !isCancellation(error) else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                pendingAttempt = nil
                activeMutationID = nil
                await reconcileMissingEntity(loadID: nil)
            } else if isDefinitiveWriteFailure(error) {
                commentSubmission = .failed
                pendingAttempt = nil
                activeMutationID = nil
            } else {
                commentSubmission = .checkingResult
                await checkPendingCommentOutcome(mutationID: mutationID)
            }
        }
    }

    func loadWorkerLog() async {
        guard workerLogState != .loading else { return }
        workerLogState = .loading
        do {
            let log = try await client.kanbanWorkerLog(
                KanbanWorkerLogRequest(cardID: cardID, board: board)
            )
            guard !Task.isCancelled else { return }
            guard log.cardID == nil || normalized(log.cardID) == normalized(cardID) else {
                workerLogState = .failed
                return
            }
            workerLogState = log.exists == false || (log.content ?? "").isEmpty ? .absent : .loaded(log)
        } catch {
            guard !isCancellation(error) else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                await reconcileMissingEntity(loadID: nil)
            }
            workerLogState = .failed
        }
    }

    private func fetchDetail(showsLoadingState: Bool) async {
        guard activeMutationID == nil else { return }
        let loadID = UUID()
        activeDetailLoadID = loadID
        if showsLoadingState { loadState = .loading }
        do {
            let response = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(response, requestedCardID: cardID)
            guard !Task.isCancelled, activeDetailLoadID == loadID, activeMutationID == nil else { return }
            detail = response
            loadState = .loaded
            onDetailLoaded(response)
        } catch {
            guard activeDetailLoadID == loadID, activeMutationID == nil else { return }
            guard !isCancellation(error) else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                await reconcileMissingEntity(loadID: loadID)
            } else {
                loadState = .failed
            }
        }
    }

    private func checkPendingCommentOutcome(mutationID: UUID? = nil) async {
        guard let attempt = pendingAttempt else { return }
        let expectedMutationID = mutationID ?? activeMutationID ?? UUID()
        if activeMutationID == nil { activeMutationID = expectedMutationID }
        commentSubmission = .checkingResult
        do {
            let response = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(response, requestedCardID: cardID)
            guard !Task.isCancelled, activeMutationID == expectedMutationID else { return }
            detail = response
            loadState = .loaded
            onDetailLoaded(response)
            if attempt.appears(in: response.comments ?? []) {
                commentDraft = ""
                commentSubmission = .succeeded
            } else {
                commentSubmission = .failed
            }
            pendingAttempt = nil
            activeMutationID = nil
        } catch {
            guard activeMutationID == expectedMutationID else { return }
            guard !isCancellation(error) else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                pendingAttempt = nil
                activeMutationID = nil
                await reconcileMissingEntity(loadID: nil)
            } else {
                commentSubmission = .outcomeUncertain
                activeMutationID = nil
            }
        }
    }

    private func reconcileMissingEntity(loadID: UUID?) async {
        let expectedDetailLoadID = loadID ?? activeDetailLoadID
        do {
            let response = try await client.kanbanBoards()
            guard !Task.isCancelled, activeDetailLoadID == expectedDetailLoadID else { return }
            let boardExists = (response.boards ?? []).contains {
                normalized($0.slug) == normalized(board)
            }
            detail = nil
            loadState = boardExists ? .missingCard : .missingBoard
        } catch {
            guard activeDetailLoadID == expectedDetailLoadID else { return }
            guard !isCancellation(error) else { return }
            forwardAuthentication(error)
            loadState = .failed
        }
    }

    private func isDefinitiveWriteFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .unauthorized, .invalidServerURL:
            return true
        case let .http(statusCode, _):
            return (400..<500).contains(statusCode) && statusCode != 408
        case .network, .decoding:
            return false
        }
    }

    private func isNotFound(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
    }

    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }

        let underlying: Error
        if case let APIError.network(wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }
        return (underlying as? URLError)?.code == .cancelled
    }

    private func forwardAuthentication(_ error: Error) {
        if case APIError.unauthorized = error { onAPIError(error) }
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct PendingCommentAttempt {
    let body: String
    let baselineIDs: Set<String>
    let baselineMatchingBodyCount: Int

    init(body: String, baseline: [KanbanComment]) {
        self.body = body
        baselineIDs = Set(baseline.compactMap(\.commentID))
        baselineMatchingBodyCount = baseline.count { comment in
            comment.body?.trimmingCharacters(in: .whitespacesAndNewlines) == body
        }
    }

    func appears(in comments: [KanbanComment]) -> Bool {
        let matching = comments.filter {
            $0.body?.trimmingCharacters(in: .whitespacesAndNewlines) == body
        }
        if matching.contains(where: { comment in
            guard let id = comment.commentID else { return false }
            return !baselineIDs.contains(id)
        }) {
            return true
        }
        return matching.count > baselineMatchingBodyCount
    }
}
