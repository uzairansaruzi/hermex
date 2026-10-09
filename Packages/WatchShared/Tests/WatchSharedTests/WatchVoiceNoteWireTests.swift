import Foundation
import Testing
@testable import WatchShared

@Suite struct WatchVoiceNoteWireTests {
    @Test func inlineBudgetFitsSendMessageAfterBase64() throws {
        let request = try sampleNote(
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x1, count: WatchVoiceNoteWire.maximumInlineAudioBytes)
        )
        let payload = try JSONEncoder().encode(WatchWireMessage.transcribe(request))
        #expect(payload.count <= WatchVoiceNoteWire.maximumSendMessagePayloadBytes)
        #expect(payload.count > 60_000)
        #expect(WatchVoiceNoteWire.requiresFileTransfer(request) == false)
    }

    @Test func audioOverInlineBudgetUsesFileTransfer() throws {
        let request = try sampleNote(
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x1, count: WatchVoiceNoteWire.maximumInlineAudioBytes + 1)
        )
        #expect(WatchVoiceNoteWire.requiresFileTransfer(request))
        #expect(request.audio.count <= WatchVoiceNoteRequest.maximumAudioBytes)
    }

    @Test func fiveMinuteIOSBudgetFitsTheDomainCap() throws {
        let documented = WatchVoiceNoteAudioBudget.bytes(
            bitsPerSecond: WatchVoiceNoteAudioBudget.documentedBitsPerSecond,
            duration: WatchVoiceNoteAudioBudget.maximumDuration
        )
        let medium = WatchVoiceNoteAudioBudget.bytes(
            bitsPerSecond: WatchVoiceNoteAudioBudget.mediumQualityBitsPerSecond,
            duration: WatchVoiceNoteAudioBudget.maximumDuration
        )
        #expect(WatchVoiceNoteAudioBudget.maximumDuration == 300)
        #expect(documented == 1_200_000)
        #expect(medium == 2_400_000)
        #expect(WatchVoiceNoteRequest.maximumAudioBytes == 3_000_000)
        #expect(documented <= WatchVoiceNoteRequest.maximumAudioBytes)
        #expect(medium <= WatchVoiceNoteRequest.maximumAudioBytes)
        #expect(WatchVoiceNoteRequest.maximumAudioBytes < WatchVoiceNoteAudioBudget.transcribeUploadCapBytes)
        #expect(WatchVoiceNoteWire.maximumInlineAudioBytes == 48_000)

        let fiveMinuteClip = try sampleNote(
            filename: "voice-note-five.m4a",
            audio: Data(repeating: 0x1, count: documented)
        )
        #expect(WatchVoiceNoteWire.requiresFileTransfer(fiveMinuteClip))
    }

    @Test func domainCapRejectsOversizedAudio() throws {
        #expect(WatchVoiceNoteRequest.maximumAudioBytes == WatchVoiceNoteAudioBudget.maximumAudioBytes)
        #expect(throws: WatchVoiceNoteValidationError.audioTooLarge) {
            try sampleNote(
                filename: "voice-note-test.m4a",
                audio: Data(repeating: 0x1, count: WatchVoiceNoteRequest.maximumAudioBytes + 1)
            )
        }
        let accepted = try sampleNote(
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x1, count: WatchVoiceNoteRequest.maximumAudioBytes)
        )
        #expect(accepted.audio.count == WatchVoiceNoteRequest.maximumAudioBytes)
    }

    @Test func fileRefRoundTripRebuildsTheRequest() throws {
        let audio = Data(repeating: 0xAB, count: 64)
        let request = try sampleNote(
            revision: Revision(3),
            filename: "voice-note-hop.m4a",
            audio: audio
        )
        let transferID = UUID()
        let ref = try request.fileRef(transferID: transferID)
        let encoded = try JSONEncoder().encode(WatchWireMessage.transcribeFile(ref))
        let decoded = try JSONDecoder().decode(WatchWireMessage.self, from: encoded)
        guard case .transcribeFile(let roundTripped) = decoded else {
            Issue.record("expected transcribeFile")
            return
        }
        #expect(roundTripped.transferID == transferID)
        #expect(roundTripped.audioByteCount == 64)
        #expect(try roundTripped.makeRequest(audio: audio) == request)
    }

    @Test func inboxServesTakeAfterDeposit() async throws {
        let inbox = WatchVoiceNoteFileInbox()
        let transferID = UUID()
        let payload = Data([0x1, 0x2, 0x3])
        await inbox.deposit(transferID: transferID, data: payload)
        #expect(try await inbox.take(transferID: transferID) == payload)
    }

    @Test func inboxGivesDepositedFileToWaitingTake() async throws {
        let inbox = WatchVoiceNoteFileInbox()
        let transferID = UUID()
        let payload = Data([0x9, 0x8])
        async let taken = inbox.take(transferID: transferID)
        await inbox.deposit(transferID: transferID, data: payload)
        #expect(try await taken == payload)
    }

    @Test func fileHopJoinsAudioBeforeDispatch() async throws {
        let backend = FileHopBackend()
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let dispatcher = WatchWireDispatcher(service: broker) { request in
            await broker.sendVoiceNote(request)
        }
        let client = WatchWireClient(transport: FileHopTransport(dispatcher: dispatcher))
        let registry = await client.registry()
        let scope = try #require(registry.entries.first?.scope)
        let note = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-file.m4a",
            audio: Data(repeating: 0x3, count: WatchVoiceNoteWire.maximumInlineAudioBytes + 8)
        )
        let receipt = try await client.sendVoiceNote(note)
        #expect(receipt.value?.streamID == "stream-1")
        #expect(backend.transcribedByteCounts == [note.audio.count])
        #expect(backend.uploadedByteCounts == [note.audio.count])
        #expect(backend.startedMessages == ["file-hop-ok"])
        #expect(backend.startedAttachmentPaths == ["/tmp/workspace/voice-note-file.m4a"])
    }

    @Test func sendVoiceNoteWireFailureDoesNotReturnARun() async throws {
        let backend = FileHopBackend()
        backend.failUpload = true
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let dispatcher = WatchWireDispatcher(service: broker) { request in
            await broker.sendVoiceNote(request)
        }
        let client = WatchWireClient(transport: FileHopTransport(dispatcher: dispatcher))
        let registry = await client.registry()
        let scope = try #require(registry.entries.first?.scope)
        let note = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-file.m4a",
            audio: Data(repeating: 0x3, count: 32)
        )
        do {
            _ = try await client.sendVoiceNote(note)
            Issue.record("sendVoiceNote should have thrown after upload failure")
        } catch WatchCompanionError.backend(.invalidResponse) {
            // expected: dispatcher maps a rejected receipt to a failure reply
        }
        #expect(backend.startedMessages.isEmpty)
    }

    @Test func unresolvedFileRefFailsClosed() async {
        let backend = FileHopBackend()
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let dispatcher = WatchWireDispatcher(service: broker)
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try! Generation(1)
        )
        let ref = try! WatchVoiceNoteFileRef(
            transferID: UUID(),
            scope: scope,
            expectedRevision: Revision(1),
            session: try! SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-missing.m4a",
            audioByteCount: 32
        )
        let reply = await dispatcher.handle(.transcribeFile(ref))
        guard case .failure(.rejected(_, let code)) = reply else {
            Issue.record("expected unresolved file hop to reject")
            return
        }
        #expect(code == "transcribeFileUnresolved")
    }

    private func sampleScope() -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try! Generation(1)
        )
    }

    private func sampleNote(
        revision: Revision = Revision(1),
        filename: String,
        audio: Data
    ) throws -> WatchVoiceNoteRequest {
        let scope = sampleScope()
        return try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: filename,
            audio: audio
        )
    }
}

private final class FileHopTransport: WatchWireTransporting, @unchecked Sendable {
    let dispatcher: WatchWireDispatcher
    let inbox = WatchVoiceNoteFileInbox()

    init(dispatcher: WatchWireDispatcher) {
        self.dispatcher = dispatcher
    }

    func send(_ message: WatchWireMessage) async throws -> WatchWireReply {
        guard case .transcribe(let request) = message, WatchVoiceNoteWire.requiresFileTransfer(request) else {
            return await dispatcher.handle(message)
        }
        let transferID = UUID()
        await inbox.deposit(transferID: transferID, data: request.audio)
        let audio = try await inbox.take(transferID: transferID)
        return await dispatcher.handle(.transcribe(try request.fileRef(transferID: transferID).makeRequest(audio: audio)))
    }
}

private final class FileHopBackend: WatchPhoneBackend, @unchecked Sendable {
    var transcribedByteCounts: [Int] = []
    var uploadedByteCounts: [Int] = []
    var startedMessages: [String] = []
    var startedAttachmentPaths: [String] = []
    var failUpload = false

    func servers() async -> [WatchPhoneServerAccount] {
        [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
    }
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] { [] }
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { "s2" }
    func startChat(urlString: String, sessionID: String, message: String) async throws -> String { "stream-1" }
    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String {
        startedMessages.append(message)
        startedAttachmentPaths.append(contentsOf: attachments?.map(\.path) ?? [])
        return "stream-1"
    }
    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment {
        uploadedByteCounts.append(data.count)
        if failUpload { throw WatchCompanionError.backend(.timeout) }
        return WatchChatAttachment(
            name: filename,
            path: "/tmp/workspace/\(filename)",
            mime: "audio/m4a",
            size: data.count,
            isImage: false
        )
    }
    func cancelChat(urlString: String, streamID: String) async throws {}
    func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage {
        WatchPhoneTranscriptPage(blocks: [], nextBefore: nil, isTruncated: false)
    }
    func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool) {
        (.responding, false)
    }
    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String {
        transcribedByteCounts.append(data.count)
        return "file-hop-ok"
    }
}
