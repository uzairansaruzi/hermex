import XCTest
@testable import HermesMobile

@MainActor final class BotDraftTests: XCTestCase {
    private let one = URL(string: "https://one.example")!
    private let two = URL(string: "https://two.example")!

    func testDiskRoundTripSeparatesServersConnectionsProfilesAndWebui() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let connection = UUID()
        let keys: [ChatDraftKey] = [
            .bot(server: one, connectionID: connection, profile: "same"),
            .bot(server: two, connectionID: connection, profile: "same"),
            .bot(server: one, connectionID: UUID(), profile: "same"),
            .bot(server: one, connectionID: connection, profile: "other"),
            .session(server: one, sessionID: "same"), .newChat(server: one)
        ]
        let drafts = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(60))
        for (index, key) in keys.enumerated() { drafts.setDraft("draft \(index)", for: key) }
        drafts.setBotSubmissionUncertain(true, for: keys[0])
        try await drafts.flush()
        let restored = await persistence.load()
        XCTAssertEqual(restored.count, keys.count)
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(restored[key]?.text, "draft \(index)")
            XCTAssertEqual(restored[key]?.botSubmissionUncertain, index == 0)
        }
        await drafts.discardBotDrafts(server: one, connectionID: connection)
        try await drafts.flush()
        let afterConnectionRemoval = await persistence.load()
        XCTAssertNil(afterConnectionRemoval[keys[0]])
        XCTAssertNil(afterConnectionRemoval[keys[3]])
        XCTAssertNotNil(afterConnectionRemoval[keys[1]])
        XCTAssertNotNil(afterConnectionRemoval[keys[2]])
        XCTAssertNotNil(afterConnectionRemoval[keys[4]])
        await drafts.discardDrafts(for: one)
        try await drafts.flush()
        let afterServerRemoval = await persistence.load()
        XCTAssertEqual(Set(afterServerRemoval.keys), [keys[1]])
    }

    func testOlderDraftCodecAndMalformedBotRecordsPreserveWebui() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftDirectory = directory.appendingPathComponent("ChatDrafts")
        try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        {"version": 3, "drafts": [
          {"serverID":"https://one.example", "context":"session", "sessionID":"same", "text":"old webui"},
          {"serverID":"https://one.example", "context":"bot", "connectionID":"\(id)", "profile":"same", "text":"held", "botSubmissionUncertain":"malformed"},
          {"serverID":"https://one.example", "context":"bot", "connectionID":"not-uuid", "profile":"same", "text":"bad identity"},
          {"serverID":"https://one.example", "context":"future", "text":"unknown"}
        ]}
        """
        try Data(json.utf8).write(to: draftDirectory.appendingPathComponent("drafts.json"))
        let restored = await ChatDraftFilePersistence(directoryURL: directory).load()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[.session(server: one, sessionID: "same")]?.text, "old webui")
        XCTAssertTrue(restored[.bot(server: one, connectionID: id, profile: "same")]?.botSubmissionUncertain == true)
    }

    func testConnectionKeychainScopesAndRemoval() throws {
        let keychain = InMemoryKeychainStore()
        let store = BotConnectionStore(keychain: keychain)
        let first = BotConnection(id: UUID(), name: "One", address: try BotConnection.address("http://hermes.local:9120"), username: "first", password: "fixture-one")
        let second = BotConnection(id: UUID(), name: "Two", address: first.address, username: "second", password: "fixture-two")
        try store.save(first, server: one)
        try store.save(second, server: two)
        XCTAssertEqual(try store.load(server: one), first)
        XCTAssertEqual(try store.load(server: two), second)
        try store.remove(server: one)
        XCTAssertNil(try store.load(server: one))
        XCTAssertEqual(try store.load(server: two), second)
    }

    func testAddressValidationAndOptionalRosterMetadata() throws {
        for text in ["https://user:password@host", "https://host/path", "https://host?ticket=x", "file:///tmp/host", "https://host#x"] {
            XCTAssertThrowsError(try BotConnection.address(text))
        }
        XCTAssertEqual(try BotConnection.address(" HTTP://HERMES.LOCAL:9120/ ").absoluteString, "http://hermes.local:9120")
        let profile = try XCTUnwrap(BotProfile(.object(["name": .string("same"), "future": .array([])])))
        XCTAssertEqual(profile.name, "same")
        XCTAssertNil(profile.preview)
        XCTAssertNil(profile.lastActive)
    }
}
