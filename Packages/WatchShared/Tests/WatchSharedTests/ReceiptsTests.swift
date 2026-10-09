import Foundation
import Testing
@testable import WatchShared

private enum RecordingReceiptLedgerError: Error {
    case missingReceipt
}

private actor RecordingReceiptLedger: WatchReceiptLedger {
    struct Retirement: Equatable, Sendable {
        let scope: ServerScope
        let afterAllCommandsExpiredAt: Date
    }

    private var receipts: [CommandID: MutationReceipt] = [:]
    private var retirements: [Retirement] = []

    func recordDispatching(
        context: CommandContext,
        operationKind: WatchOperationKind
    ) async throws {
        receipts[context.stableCommandID] = try MutationReceipt(
            context: context,
            operationKind: operationKind,
            phase: .dispatching,
            updatedAt: context.createdAt,
            nonSecretResultID: nil
        )
    }

    func transition(
        id: CommandID,
        to phase: ReceiptPhase,
        at: Date,
        nonSecretResultID: String?
    ) async throws {
        guard let existing = receipts[id] else {
            throw RecordingReceiptLedgerError.missingReceipt
        }
        receipts[id] = try MutationReceipt(
            context: existing.context,
            operationKind: existing.operationKind,
            phase: phase,
            updatedAt: at,
            nonSecretResultID: nonSecretResultID
        )
    }

    func receipt(id: CommandID) async throws -> MutationReceipt? {
        receipts[id]
    }

    func retireSafetyGeneration(
        _ scope: ServerScope,
        afterAllCommandsExpiredAt: Date
    ) async throws {
        retirements.append(
            Retirement(
                scope: scope,
                afterAllCommandsExpiredAt: afterAllCommandsExpiredAt
            )
        )
    }

    func recordedRetirements() -> [Retirement] {
        retirements
    }
}

@Suite struct ReceiptsTests {
    private func context() throws -> CommandContext {
        let scope = ServerScope(
            epoch: InstallationEpoch(
                rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            ),
            server: ServerID(
                rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            ),
            generation: try Generation(7)
        )
        let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
        return try CommandContext(
            stableCommandID: CommandID(
                rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ),
            scope: scope,
            expectedRevision: Revision(11),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(60)
        )
    }

    private func mutationReceipt(
        phase: ReceiptPhase = .acknowledged,
        resultID: String? = "result_42"
    ) throws -> MutationReceipt {
        let context = try context()
        return try MutationReceipt(
            context: context,
            operationKind: .stop,
            phase: phase,
            updatedAt: context.createdAt.addingTimeInterval(5),
            nonSecretResultID: resultID
        )
    }

    @Test func semanticCoverage_ReceiptPhase() throws {
        let phases: [ReceiptPhase] = [
            .dispatching,
            .definitelyNotSent,
            .acknowledged,
            .reconciled,
            .rejected,
            .uncertain,
        ]
        #expect(phases.map(\.rawValue) == [
            "dispatching",
            "definitelyNotSent",
            "acknowledged",
            "reconciled",
            "rejected",
            "uncertain",
        ])

        for phase in phases {
            let encoded = try JSONEncoder().encode(phase)
            #expect(try JSONDecoder().decode(ReceiptPhase.self, from: encoded) == phase)
        }

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReceiptPhase.self, from: Data(#""future""#.utf8))
        }
    }

    @Test func semanticCoverage_MutationReceipt() throws {
        let receipt = try mutationReceipt()
        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(MutationReceipt.self, from: encoded)
        #expect(decoded == receipt)
        #expect(decoded.operationKind == .stop)
        #expect(decoded.phase == .acknowledged)
        #expect(decoded.nonSecretResultID == "result_42")

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["updatedAt"] = receipt.context.createdAt.timeIntervalSinceReferenceDate - 1
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MutationReceipt.self, from: invalid)
        }
    }

    @Test func semanticCoverage_CommandReceipt() throws {
        let receipt = try mutationReceipt(phase: .reconciled)
        let commandReceipt = CommandReceipt(receipt: receipt, value: EmptyValue())
        let encoded = try JSONEncoder().encode(commandReceipt)
        let decoded = try JSONDecoder().decode(
            CommandReceipt<EmptyValue>.self,
            from: encoded
        )
        #expect(decoded == commandReceipt)
        #expect(decoded.receipt.phase == .reconciled)
        #expect(decoded.value == EmptyValue())

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var nestedReceipt = try #require(object["receipt"] as? [String: Any])
        nestedReceipt["phase"] = "future"
        object["receipt"] = nestedReceipt
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CommandReceipt<EmptyValue>.self, from: invalid)
        }
    }

    @Test func semanticCoverage_EmptyValue() throws {
        let value = EmptyValue()
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(EmptyValue.self, from: encoded) == value)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EmptyValue.self, from: Data("{".utf8))
        }
    }

    @Test func semanticCoverage_WatchTransportFailure() throws {
        let failures: [WatchTransportFailure] = [
            .definitelyNotSent(code: "offline"),
            .uncertain(code: "connection_lost"),
            .rejected(status: 409, sanitizedCode: "attentionExactIDUnavailable"),
            .invalidEnvelope(code: "scope_mismatch"),
        ]
        for failure in failures {
            let encoded = try JSONEncoder().encode(failure)
            #expect(
                try JSONDecoder().decode(WatchTransportFailure.self, from: encoded)
                    == failure
            )
        }

        let invalid: [WatchTransportFailure] = [
            .definitelyNotSent(code: " "),
            .uncertain(code: String(repeating: "x", count: 257)),
            .invalidEnvelope(code: "Authorization: Bearer secret"),
            .rejected(status: 99, sanitizedCode: "bad"),
        ]
        for failure in invalid {
            let encoded = try JSONEncoder().encode(failure)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchTransportFailure.self, from: encoded)
            }
        }
    }

    @Test func semanticCoverage_WatchReceiptLedger() async throws {
        let ledger = RecordingReceiptLedger()
        let contract: any WatchReceiptLedger = ledger
        #expect(contract is RecordingReceiptLedger)
        let commandContext = try context()
        let transitionDate = commandContext.createdAt.addingTimeInterval(10)

        try await contract.recordDispatching(
            context: commandContext,
            operationKind: .interruptBot
        )
        let dispatched = try #require(
            try await contract.receipt(id: commandContext.stableCommandID)
        )
        #expect(dispatched.context == commandContext)
        #expect(dispatched.operationKind == .interruptBot)
        #expect(dispatched.phase == .dispatching)
        #expect(dispatched.updatedAt == commandContext.createdAt)
        #expect(dispatched.nonSecretResultID == nil)

        try await contract.transition(
            id: commandContext.stableCommandID,
            to: .reconciled,
            at: transitionDate,
            nonSecretResultID: "result_99"
        )
        let transitioned = try #require(
            try await contract.receipt(id: commandContext.stableCommandID)
        )
        #expect(transitioned.context == commandContext)
        #expect(transitioned.operationKind == .interruptBot)
        #expect(transitioned.phase == .reconciled)
        #expect(transitioned.updatedAt == transitionDate)
        #expect(transitioned.nonSecretResultID == "result_99")

        let retirementDate = commandContext.expiresAt.addingTimeInterval(1)
        try await contract.retireSafetyGeneration(
            commandContext.scope,
            afterAllCommandsExpiredAt: retirementDate
        )
        #expect(await ledger.recordedRetirements() == [
            RecordingReceiptLedger.Retirement(
                scope: commandContext.scope,
                afterAllCommandsExpiredAt: retirementDate
            )
        ])

        let unknownID = CommandID(
            rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        #expect(try await contract.receipt(id: unknownID) == nil)
    }
}
