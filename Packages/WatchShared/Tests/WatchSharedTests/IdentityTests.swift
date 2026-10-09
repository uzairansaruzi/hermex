import Foundation
import Testing
@testable import WatchShared

@Suite struct IdentityTests {
    @Test func installationEpochRoundTripsWithNestedCanonicalUUID() throws {
        let uuid = UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!
        let value = InstallationEpoch(rawValue: uuid)

        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["rawValue": uuid.uuidString])
        #expect(try JSONDecoder().decode(InstallationEpoch.self, from: data) == value)
    }

    @Test func serverIDRoundTripsWithNestedCanonicalUUIDIncludingNilUUID() throws {
        let value = ServerID(rawValue: UUID())
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ServerID.self, from: data) == value)

        let nilValue = ServerID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        #expect(try JSONDecoder().decode(ServerID.self, from: JSONEncoder().encode(nilValue)) == nilValue)
    }

    @Test func generationRejectsZeroAtInitialization() {
        #expect(throws: IdentityValidationError.generationMustBePositive) {
            try Generation(0)
        }
    }

    @Test func generationUsesSingleIntegerAndValidatesDecoding() throws {
        let value = try Generation(7)
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self) == "7")
        #expect(try JSONDecoder().decode(Generation.self, from: data) == value)
        #expect(throws: IdentityValidationError.generationMustBePositive) {
            try JSONDecoder().decode(Generation.self, from: Data("0".utf8))
        }
    }

    @Test func serverScopeCarriesEpochServerAndGeneration() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let server = ServerID(rawValue: UUID())
        let generation = try Generation(3)
        let scope = ServerScope(epoch: epoch, server: server, generation: generation)
        #expect(scope.epoch == epoch)
        #expect(scope.server == server)
        #expect(scope.generation == generation)
        #expect(try JSONDecoder().decode(ServerScope.self, from: JSONEncoder().encode(scope)) == scope)
    }

    @Test func revisionUsesSingleNonnegativeInteger() throws {
        let zero = Revision(0)
        #expect(String(decoding: try JSONEncoder().encode(zero), as: UTF8.self) == "0")
        #expect(try JSONDecoder().decode(Revision.self, from: Data("42".utf8)) == Revision(42))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Revision.self, from: Data("-1".utf8))
        }
    }

    @Test func sessionKeyPreservesAcceptedIdentifierBytes() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let original = "  Session/Ω  "
        let key = try SessionKey(scope: scope, sessionID: original)
        #expect(key.scope == scope)
        #expect(key.sessionID == original)
    }

    @Test func sessionKeyRejectsBlankOnlyIdentifier() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try SessionKey(scope: scope, sessionID: " \t\n ")
        }
    }

    @Test func sessionKeyEnforcesUTF8ByteLimit() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        #expect(try SessionKey(scope: scope, sessionID: String(repeating: "a", count: 256)).sessionID.utf8.count == 256)
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: 256)) {
            try SessionKey(scope: scope, sessionID: String(repeating: "é", count: 129))
        }
    }

    @Test func sessionKeyDecodingRevalidatesIdentifier() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let valid = try SessionKey(scope: scope, sessionID: "valid")
        #expect(try JSONDecoder().decode(SessionKey.self, from: JSONEncoder().encode(valid)) == valid)

        let invalid = Data("{\"scope\":\(String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)),\"sessionID\":\"   \"}".utf8)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try JSONDecoder().decode(SessionKey.self, from: invalid)
        }
    }

    @Test func botKeyPreservesProfileBytesAndTypedConnection() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let connectionID = UUID()
        let original = "  Profile/Ω  "
        let key = try BotKey(scope: scope, connectionID: connectionID, profile: original)
        #expect(key.scope == scope)
        #expect(key.connectionID == connectionID)
        #expect(key.profile == original)
    }

    @Test func botKeyRejectsBlankAndOver128UTF8Profiles() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try BotKey(scope: scope, connectionID: UUID(), profile: " \n")
        }
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: 128)) {
            try BotKey(scope: scope, connectionID: UUID(), profile: String(repeating: "é", count: 65))
        }
    }

    @Test func botKeyDecodingRevalidatesProfile() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let valid = try BotKey(scope: scope, connectionID: UUID(), profile: "profile")
        #expect(try JSONDecoder().decode(BotKey.self, from: JSONEncoder().encode(valid)) == valid)

        let scopeJSON = String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
        let invalid = Data("{\"scope\":\(scopeJSON),\"connectionID\":\"\(UUID().uuidString)\",\"profile\":\"\"}".utf8)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try JSONDecoder().decode(BotKey.self, from: invalid)
        }
    }

    @Test func extendedIdentityTypesAreDistinctValidatedAndRoundTrip() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let session = try SessionKey(scope: scope, sessionID: "session")
        let values: [any Codable & Sendable] = [
            try RunKey(session: session, streamID: "stream"),
            try TaskKey(scope: scope, jobID: "job"),
            try ApprovalKey(session: session, remoteID: "approval"),
            try ClarificationKey(session: session, remoteID: "clarification"),
            try ProfileID("profile"), try WorkspaceHandle("workspace"), try PathHandle("path-handle"),
            try MediaHandle("media"), DraftHandle(rawValue: UUID()), try OriginBinding(digest: "sha256:abc"),
            try SkillKey(scope: scope, name: "skill"), try MemoryKey(scope: scope, remoteID: "memory"),
            try InsightKey(scope: scope, remoteID: "insight")
        ]
        #expect(values.count == 13)
        let run = try RunKey(session: session, streamID: "stream")
        #expect(try JSONDecoder().decode(RunKey.self, from: JSONEncoder().encode(run)) == run)
        #expect(throws: IdentityValidationError.blankIdentifier) { try ProfileID(" \n") }
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: 256)) { try PathHandle(String(repeating: "é", count: 129)) }
    }
}

private func semanticIdentityScope() throws -> ServerScope {
    ServerScope(
        epoch: InstallationEpoch(rawValue: UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!),
        server: ServerID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
        generation: try Generation(7)
    )
}

private func semanticIdentitySession() throws -> SessionKey {
    try SessionKey(scope: semanticIdentityScope(), sessionID: "session-Ω")
}

@Suite struct IdentitySemanticCoverageTests {
    @Test func semanticCoverage_ApprovalKey() throws {
        let value: ApprovalKey = try ApprovalKey(session: semanticIdentitySession(), remoteID: "approval-Ω")
        #expect(value.remoteID == "approval-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ApprovalKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try ApprovalKey(session: semanticIdentitySession(), remoteID: " \n")
        }
    }

    @Test func semanticCoverage_BotKey() throws {
        let value: BotKey = try BotKey(
            scope: semanticIdentityScope(),
            connectionID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!,
            profile: "profile-Ω"
        )
        #expect(value.profile == "profile-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(BotKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: ContractLimits.profileUTF8Bytes)) {
            try BotKey(scope: semanticIdentityScope(), connectionID: UUID(), profile: String(repeating: "p", count: ContractLimits.profileUTF8Bytes + 1))
        }
    }

    @Test func semanticCoverage_ClarificationKey() throws {
        let value: ClarificationKey = try ClarificationKey(session: semanticIdentitySession(), remoteID: "clarification-Ω")
        #expect(value.remoteID == "clarification-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ClarificationKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try ClarificationKey(session: semanticIdentitySession(), remoteID: "\t")
        }
    }

    @Test func semanticCoverage_ContractLimits() throws {
        #expect(ContractLimits.identifierUTF8Bytes == 256)
        #expect(ContractLimits.profileUTF8Bytes == 128)
        #expect(ContractLimits.displayNameUTF8Bytes == 64)
        #expect(ContractLimits.registryEntries == 32)
        #expect(ContractLimits.routeJSONBytes == 1_024)
        #expect(ContractLimits.widgetJSONBytes == 4_096)

        let identifier = try ProfileID(String(repeating: "i", count: ContractLimits.identifierUTF8Bytes))
        #expect(identifier.rawValue.utf8.count == 256)
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: 256)) {
            try ProfileID(String(repeating: "i", count: ContractLimits.identifierUTF8Bytes + 1))
        }

        let profile = try BotKey(
            scope: semanticIdentityScope(),
            connectionID: UUID(),
            profile: String(repeating: "p", count: ContractLimits.profileUTF8Bytes)
        )
        #expect(profile.profile.utf8.count == 128)
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: 128)) {
            try BotKey(scope: semanticIdentityScope(), connectionID: UUID(), profile: String(repeating: "p", count: ContractLimits.profileUTF8Bytes + 1))
        }

        let displayName = try RedactedDisplayName(String(repeating: "d", count: ContractLimits.displayNameUTF8Bytes))
        #expect(displayName.rawValue.utf8.count == 64)
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try RedactedDisplayName(String(repeating: "d", count: ContractLimits.displayNameUTF8Bytes + 1))
        }

        let epoch = try semanticIdentityScope().epoch
        let entries = try (0..<ContractLimits.registryEntries).map { index in
            RegistryEntry(
                scope: ServerScope(epoch: epoch, server: ServerID(rawValue: UUID()), generation: try Generation(UInt64(index + 1))),
                displayName: try RedactedDisplayName("server-\(index)")
            )
        }
        let registry = try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(timeIntervalSinceReferenceDate: 10), entries: entries)
        #expect(registry.entries.count == 32)
        #expect(throws: RegistryValidationError.tooManyEntries) {
            try RegistrySnapshot(epoch: epoch, revision: Revision(1), generatedAt: Date(timeIntervalSinceReferenceDate: 10), entries: entries + [RegistryEntry(scope: ServerScope(epoch: epoch, server: ServerID(rawValue: UUID()), generation: try Generation(33)), displayName: try RedactedDisplayName("overflow"))])
        }

        let route: RedactedRoute = .sessions(try semanticIdentityScope())
        var routeData = try route.canonicalJSONData()
        routeData.append(contentsOf: repeatElement(UInt8(32), count: ContractLimits.routeJSONBytes - routeData.count))
        #expect(routeData.count == 1_024)
        #expect(try RedactedRoute.decode(routeData) == route)
        routeData.append(32)
        #expect(throws: RouteValidationError.tooLarge) { try RedactedRoute.decode(routeData) }

        let scope = try semanticIdentityScope()
        let widget = try RedactedWidgetSnapshot(
            scope: scope,
            displayName: displayName,
            activity: .needsAttention,
            attentionCount: 1,
            observedAt: Date(timeIntervalSinceReferenceDate: 10),
            route: .sessions(scope)
        )
        var widgetData = try widget.canonicalJSONData()
        widgetData.append(contentsOf: repeatElement(UInt8(32), count: ContractLimits.widgetJSONBytes - widgetData.count))
        #expect(widgetData.count == 4_096)
        #expect(try RedactedWidgetSnapshot.decode(widgetData) == widget)
        widgetData.append(32)
        #expect(throws: WidgetValidationError.tooLarge) { try RedactedWidgetSnapshot.decode(widgetData) }
    }

    @Test func semanticCoverage_DraftHandle() throws {
        let value: DraftHandle = DraftHandle(rawValue: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA")!)
        #expect(value.rawValue.uuidString == "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(DraftHandle.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DraftHandle.self, from: Data("{\"rawValue\":\"not-a-uuid\"}".utf8))
        }
    }

    @Test func semanticCoverage_Generation() throws {
        let value: Generation = try Generation(9)
        #expect(value.rawValue == 9)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Generation.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.generationMustBePositive) { try Generation(0) }
        #expect(throws: IdentityValidationError.generationMustBePositive) {
            try JSONDecoder().decode(Generation.self, from: Data("0".utf8))
        }
    }

    @Test func semanticCoverage_IdentityValidationError() throws {
        let generationError: IdentityValidationError = .generationMustBePositive
        let blankError: IdentityValidationError = .blankIdentifier
        let lengthError: IdentityValidationError = .identifierTooLong(maxUTF8Bytes: 17)
        #expect(generationError == .generationMustBePositive)
        #expect(blankError == .blankIdentifier)
        #expect(lengthError == .identifierTooLong(maxUTF8Bytes: 17))
        #expect(throws: generationError) { try Generation(0) }
        #expect(throws: blankError) { try ProfileID(" \n") }
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: ContractLimits.identifierUTF8Bytes)) {
            try ProfileID(String(repeating: "x", count: ContractLimits.identifierUTF8Bytes + 1))
        }
    }

    @Test func semanticCoverage_InsightKey() throws {
        let value: InsightKey = try InsightKey(scope: semanticIdentityScope(), remoteID: "insight-Ω")
        #expect(value.remoteID == "insight-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(InsightKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try InsightKey(scope: semanticIdentityScope(), remoteID: " ")
        }
    }

    @Test func semanticCoverage_InstallationEpoch() throws {
        let uuid = UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!
        let value: InstallationEpoch = InstallationEpoch(rawValue: uuid)
        #expect(value.rawValue == uuid)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(InstallationEpoch.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(InstallationEpoch.self, from: Data("{\"rawValue\":\"invalid\"}".utf8))
        }
    }

    @Test func semanticCoverage_MediaHandle() throws {
        let value: MediaHandle = try MediaHandle("media-Ω")
        #expect(value.rawValue == "media-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MediaHandle.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) { try MediaHandle("\t") }
    }

    @Test func semanticCoverage_MemoryKey() throws {
        let value: MemoryKey = try MemoryKey(scope: semanticIdentityScope(), remoteID: "memory-Ω")
        #expect(value.remoteID == "memory-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MemoryKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try MemoryKey(scope: semanticIdentityScope(), remoteID: "\n")
        }
    }

    @Test func semanticCoverage_OriginBinding() throws {
        let value: OriginBinding = try OriginBinding(digest: "sha256:0123456789abcdef")
        #expect(value.digest == "sha256:0123456789abcdef")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(OriginBinding.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) { try OriginBinding(digest: " ") }
    }

    @Test func semanticCoverage_PathHandle() throws {
        let value: PathHandle = try PathHandle("src/path-Ω")
        #expect(value.rawValue == "src/path-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PathHandle.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.identifierTooLong(maxUTF8Bytes: ContractLimits.identifierUTF8Bytes)) {
            try PathHandle(String(repeating: "é", count: 129))
        }
    }

    @Test func semanticCoverage_ProfileID() throws {
        let value: ProfileID = try ProfileID("profile-Ω")
        #expect(value.rawValue == "profile-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ProfileID.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) { try ProfileID(" \t") }
    }

    @Test func semanticCoverage_Revision() throws {
        let value: Revision = Revision(42)
        #expect(value.rawValue == 42)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Revision.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Revision.self, from: Data("-1".utf8))
        }
    }

    @Test func semanticCoverage_RunKey() throws {
        let value: RunKey = try RunKey(session: semanticIdentitySession(), streamID: "stream-Ω")
        #expect(value.streamID == "stream-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RunKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try RunKey(session: semanticIdentitySession(), streamID: " ")
        }
    }

    @Test func semanticCoverage_ServerID() throws {
        let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let value: ServerID = ServerID(rawValue: uuid)
        #expect(value.rawValue == uuid)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ServerID.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ServerID.self, from: Data("{\"rawValue\":42}".utf8))
        }
    }

    @Test func semanticCoverage_ServerScope() throws {
        let value: ServerScope = try semanticIdentityScope()
        #expect(value.generation.rawValue == 7)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ServerScope.self, from: encoded)
        #expect(decoded == value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["generation"] = 0
        #expect(throws: IdentityValidationError.generationMustBePositive) {
            try JSONDecoder().decode(ServerScope.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func semanticCoverage_SessionKey() throws {
        let value: SessionKey = try semanticIdentitySession()
        #expect(value.sessionID == "session-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SessionKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try SessionKey(scope: semanticIdentityScope(), sessionID: "\n")
        }
    }

    @Test func semanticCoverage_SkillKey() throws {
        let value: SkillKey = try SkillKey(scope: semanticIdentityScope(), name: "skill-Ω")
        #expect(value.name == "skill-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SkillKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try SkillKey(scope: semanticIdentityScope(), name: " ")
        }
    }

    @Test func semanticCoverage_TaskKey() throws {
        let value: TaskKey = try TaskKey(scope: semanticIdentityScope(), jobID: "job-Ω")
        #expect(value.jobID == "job-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(TaskKey.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) {
            try TaskKey(scope: semanticIdentityScope(), jobID: "\t")
        }
    }

    @Test func semanticCoverage_WorkspaceHandle() throws {
        let value: WorkspaceHandle = try WorkspaceHandle("workspace-Ω")
        #expect(value.rawValue == "workspace-Ω")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WorkspaceHandle.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: IdentityValidationError.blankIdentifier) { try WorkspaceHandle(" ") }
    }

    @Test func unavailableWakeIsNotAnEmptyRegistry() throws {
        let wake = RegistrySnapshot.unavailableWake()
        #expect(wake.isUnavailableWake)
        let removed = try RegistrySnapshot(
            epoch: InstallationEpoch(rawValue: UUID()),
            revision: Revision(2),
            generatedAt: Date(timeIntervalSince1970: 20),
            entries: []
        )
        #expect(!removed.isUnavailableWake)
    }
}
