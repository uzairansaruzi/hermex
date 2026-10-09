import Foundation
import Testing
@testable import WatchShared

@Suite struct WatchWidgetSnapshotStoreTests {
    @Test func roundTripWritesCanonicalSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-widget-\(UUID().uuidString)", isDirectory: true)
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let snapshot = try RedactedWidgetSnapshot(
            scope: scope,
            displayName: RedactedDisplayName("Studio"),
            activity: .running,
            attentionCount: 1,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            route: .sessions(scope)
        )

        try WatchWidgetSnapshotStore.write(snapshot, directory: directory)
        let decoded = try WatchWidgetSnapshotStore.read(from: directory)

        #expect(decoded == snapshot)
    }

    @Test func voiceNoteRequestRejectsOversizedAudio() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        #expect(throws: WatchVoiceNoteValidationError.audioTooLarge) {
            try WatchVoiceNoteRequest(
                scope: scope,
                expectedRevision: Revision(1),
                session: try SessionKey(scope: scope, sessionID: "s1"),
                filename: "voice-note-test.m4a",
                audio: Data(repeating: 0x1, count: WatchVoiceNoteRequest.maximumAudioBytes + 1)
            )
        }
        let accepted = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: Revision(1),
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x1, count: 16)
        )
        #expect(accepted.audio.count == 16)
    }

    @Test func missingFileIsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-widget-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try WatchWidgetSnapshotStore.read(from: directory) == nil)
    }

    @Test func removeDropsWrittenSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-widget-remove-\(UUID().uuidString)", isDirectory: true)
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let snapshot = try RedactedWidgetSnapshot(
            scope: scope,
            displayName: RedactedDisplayName("Studio"),
            activity: .running,
            attentionCount: 1,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            route: .sessions(scope)
        )
        try WatchWidgetSnapshotStore.write(snapshot, directory: directory)
        #expect(try WatchWidgetSnapshotStore.read(from: directory) == snapshot)
        try WatchWidgetSnapshotStore.remove(from: directory)
        #expect(try WatchWidgetSnapshotStore.read(from: directory) == nil)
        try WatchWidgetSnapshotStore.remove(from: directory)
    }
}
