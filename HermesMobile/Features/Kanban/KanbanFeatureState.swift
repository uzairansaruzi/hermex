import Foundation
import Observation

enum KanbanCompatibilityState: Equatable {
    case idle
    case checking
    case compatible
    case partial
    case authenticationRequired
    case networkUnavailable
    case serverUnavailable
    case incompatibleContract
}

/// Server-bound, read-only compatibility state. It deliberately owns no
/// persisted data and starts no live-update work; those arrive in later Kanban
/// slices after this handshake has established a safe contract.
@MainActor
@Observable
final class KanbanFeatureState {
    let server: URL
    private(set) var state: KanbanCompatibilityState = .idle
    private(set) var report: KanbanCompatibilityReport?
    private(set) var isLoading = false
    private var activeLoadID: UUID?

    private let client: any KanbanDataClient
    private let onAPIError: (Error) -> Void

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.onAPIError = onAPIError
    }

    func load() async {
        let loadID = UUID()
        activeLoadID = loadID
        isLoading = true
        state = .checking
        report = nil
        defer {
            if activeLoadID == loadID {
                isLoading = false
            }
        }

        do {
            // Ordered exactly as the compatibility specification requires. These
            // are all GETs: no probes, previews, or alternate request shapes.
            let configuration = try await client.kanbanConfiguration()
            guard isCurrent(loadID) else { return }
            let boards = try await client.kanbanBoards()
            guard isCurrent(loadID) else { return }
            guard let currentBoard = boards.current?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !currentBoard.isEmpty else {
                throw KanbanContractViolation.missingCurrentBoard
            }
            let snapshot = try await client.kanbanBoard(board: currentBoard)
            guard isCurrent(loadID) else { return }

            let report = try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boards,
                snapshot: snapshot
            )
            guard isCurrent(loadID) else { return }
            self.report = report
            state = report.isPartial ? .partial : .compatible
        } catch is CancellationError {
            guard activeLoadID == loadID else { return }
            report = nil
            state = .idle
            return
        } catch {
            guard isCurrent(loadID) else { return }
            report = nil
            state = Self.classify(error)
            if case APIError.unauthorized = error {
                onAPIError(error)
            }
        }
    }

    func retry() async {
        await load()
    }

    private func isCurrent(_ loadID: UUID) -> Bool {
        activeLoadID == loadID && !Task.isCancelled
    }

    private static func classify(_ error: Error) -> KanbanCompatibilityState {
        if error is KanbanContractViolation || error is KanbanResponseError {
            return .incompatibleContract
        }
        guard let apiError = error as? APIError else {
            return .networkUnavailable
        }
        switch apiError {
        case .unauthorized:
            return .authenticationRequired
        case .network:
            return .networkUnavailable
        case let .http(statusCode, _):
            return [502, 503, 504].contains(statusCode) ? .serverUnavailable : .incompatibleContract
        case .decoding, .invalidServerURL:
            return .incompatibleContract
        }
    }
}
