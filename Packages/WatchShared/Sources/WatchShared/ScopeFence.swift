import Foundation

public enum ScopeFenceError: Error, Equatable, Sendable {
    case epochMismatch
    case olderRevision
    case conflictingEqualRevision
    case generationRollback(ServerID)
}

public enum ScopeDecision: Hashable, Sendable {
    case accept
    case reject
}

public struct ScopeFence: Hashable, Sendable {
    public let epoch: InstallationEpoch
    public private(set) var registryRevision: Revision
    public private(set) var activeScopes: [ServerID: ServerScope]
    public private(set) var highWaterGenerations: [ServerID: Generation]
    private var lastSnapshot: RegistrySnapshot?

    public init(epoch: InstallationEpoch) {
        self.epoch = epoch
        self.registryRevision = Revision(0)
        self.activeScopes = [:]
        self.highWaterGenerations = [:]
        self.lastSnapshot = nil
    }

    public mutating func apply(_ snapshot: RegistrySnapshot) throws {
        guard snapshot.epoch == epoch else {
            throw ScopeFenceError.epochMismatch
        }
        guard snapshot.revision.rawValue >= registryRevision.rawValue else {
            throw ScopeFenceError.olderRevision
        }
        if snapshot.revision == registryRevision, let lastSnapshot {
            guard snapshot == lastSnapshot else {
                throw ScopeFenceError.conflictingEqualRevision
            }
            return
        }
        for entry in snapshot.entries {
            if let highWater = highWaterGenerations[entry.scope.server] {
                let isReadd = activeScopes[entry.scope.server] == nil
                if entry.scope.generation.rawValue < highWater.rawValue ||
                    (isReadd && entry.scope.generation.rawValue == highWater.rawValue) {
                    throw ScopeFenceError.generationRollback(entry.scope.server)
                }
            }
        }
        registryRevision = snapshot.revision
        activeScopes = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.scope.server, $0.scope) })
        for entry in snapshot.entries {
            if highWaterGenerations[entry.scope.server].map({ $0.rawValue < entry.scope.generation.rawValue }) ?? true {
                highWaterGenerations[entry.scope.server] = entry.scope.generation
            }
        }
        lastSnapshot = snapshot
    }

    public func decision(for scope: ServerScope) -> ScopeDecision {
        activeScopes[scope.server] == scope ? .accept : .reject
    }
}
