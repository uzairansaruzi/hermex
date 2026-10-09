import Foundation
import Testing
@testable import WatchShared

@Suite struct ScopeFenceTests {
    private func entry(epoch: InstallationEpoch, server: ServerID = ServerID(rawValue: UUID()), generation: UInt64 = 1) throws -> RegistryEntry {
        RegistryEntry(
            scope: ServerScope(epoch: epoch, server: server, generation: try Generation(generation)),
            displayName: try RedactedDisplayName("Server")
        )
    }

    @Test func semanticCoverage_ScopeFence() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let item = try entry(epoch: epoch)
        let snapshot = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [item])
        var fence = ScopeFence(epoch: epoch)

        try fence.apply(snapshot)

        #expect(fence.epoch == epoch)
        #expect(fence.registryRevision == Revision(1))
        #expect(fence.activeScopes == [item.scope.server: item.scope])
        #expect(fence.highWaterGenerations[item.scope.server] == item.scope.generation)
    }

    @Test func semanticCoverage_ScopeFenceError() throws {
        let trusted = InstallationEpoch(rawValue: UUID())
        let other = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        var fence = ScopeFence(epoch: trusted)
        let before = fence
        let snapshot = try RegistrySnapshot(epoch: other, revision: Revision(1), generatedAt: Date(), entries: [])
        #expect(throws: ScopeFenceError.epochMismatch) { try fence.apply(snapshot) }
        #expect(fence == before)

        let errors: [ScopeFenceError] = [
            .epochMismatch,
            .olderRevision,
            .conflictingEqualRevision,
            .generationRollback(server),
        ]
        #expect(errors == [
            ScopeFenceError.epochMismatch,
            ScopeFenceError.olderRevision,
            ScopeFenceError.conflictingEqualRevision,
            ScopeFenceError.generationRollback(server),
        ])
    }

    @Test func applyRejectsOlderRevisionWithoutMutation() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let initial = try RegistrySnapshot(epoch: epoch, revision: Revision(2), generatedAt: Date(), entries: [entry(epoch: epoch)])
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(initial)
        let before = fence
        let older = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [])
        #expect(throws: ScopeFenceError.olderRevision) { try fence.apply(older) }
        #expect(fence == before)
    }

    @Test func equalRevisionAllowsOnlyIdenticalSnapshot() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let first = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(timeIntervalSinceReferenceDate: 1), entries: [entry(epoch: epoch)])
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(first)
        let before = fence
        try fence.apply(first)
        #expect(fence == before)
        let different = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(timeIntervalSinceReferenceDate: 2), entries: first.entries)
        #expect(throws: ScopeFenceError.conflictingEqualRevision) { try fence.apply(different) }
        #expect(fence == before)
    }

    @Test func removalRetainsGenerationHighWater() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        let item = try entry(epoch: epoch, server: server, generation: 4)
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [item]))
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(2), generatedAt: Date(), entries: []))
        #expect(fence.activeScopes[server] == nil)
        #expect(fence.highWaterGenerations[server] == item.scope.generation)
    }

    @Test func removedServerCanOnlyReturnAtNewerGeneration() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [entry(epoch: epoch, server: server, generation: 4)]))
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(2), generatedAt: Date(), entries: []))
        let before = fence
        let stale = try RegistrySnapshot(epoch: epoch, revision: Revision(3), generatedAt: Date(), entries: [entry(epoch: epoch, server: server, generation: 4)])
        #expect(throws: ScopeFenceError.generationRollback(server)) { try fence.apply(stale) }
        #expect(fence == before)
        let newerGeneration = try Generation(5)
        let newer = try RegistrySnapshot(epoch: epoch, revision: Revision(3), generatedAt: Date(), entries: [entry(epoch: epoch, server: server, generation: 5)])
        try fence.apply(newer)
        #expect(fence.activeScopes[server]?.generation == newerGeneration)
    }

    @Test func activeServerRejectsGenerationRollbackTransactionally() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let stableServer = ServerID(rawValue: UUID())
        let advancingServer = ServerID(rawValue: UUID())
        var fence = ScopeFence(epoch: epoch)
        let initial = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [
            entry(epoch: epoch, server: stableServer, generation: 4),
            entry(epoch: epoch, server: advancingServer, generation: 2),
        ])
        try fence.apply(initial)
        let before = fence
        let mixed = try RegistrySnapshot(epoch: epoch, revision: Revision(2), generatedAt: Date(), entries: [
            entry(epoch: epoch, server: stableServer, generation: 3),
            entry(epoch: epoch, server: advancingServer, generation: 3),
        ])
        #expect(throws: ScopeFenceError.generationRollback(stableServer)) { try fence.apply(mixed) }
        #expect(fence == before)
    }

    @Test func semanticCoverage_ScopeDecision() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        let current = try entry(epoch: epoch, server: server, generation: 4)
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [current]))

        let stale = ServerScope(epoch: epoch, server: server, generation: try Generation(3))
        let future = ServerScope(epoch: epoch, server: server, generation: try Generation(5))
        let absent = ServerScope(
            epoch: epoch,
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let decisions: [ScopeDecision] = [
            fence.decision(for: current.scope),
            fence.decision(for: stale),
            fence.decision(for: future),
            fence.decision(for: absent),
        ]

        #expect(decisions == [
            ScopeDecision.accept,
            ScopeDecision.reject,
            ScopeDecision.reject,
            ScopeDecision.reject,
        ])
    }

    @Test func tombstoneAtMaximumGenerationRejectsReaddWithoutOverflow() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        var fence = ScopeFence(epoch: epoch)
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(), entries: [entry(epoch: epoch, server: server, generation: UInt64.max)]))
        try fence.apply(RegistrySnapshot(epoch: epoch, revision: Revision(2), generatedAt: Date(), entries: []))
        let before = fence
        let readd = try RegistrySnapshot(epoch: epoch, revision: Revision(3), generatedAt: Date(), entries: [entry(epoch: epoch, server: server, generation: UInt64.max)])
        #expect(throws: ScopeFenceError.generationRollback(server)) { try fence.apply(readd) }
        #expect(fence == before)
    }
}
