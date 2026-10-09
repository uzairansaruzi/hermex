import Foundation
import Testing
@testable import WatchShared

@Suite struct WatchPhotoWireTests {
    @Test func inlineBudgetMatchesVoiceAndLargePhotosUseFileTransfer() throws {
        let small = try samplePhoto(bytes: WatchPhotoWire.maximumInlineBytes)
        #expect(WatchPhotoWire.requiresFileTransfer(small) == false)
        let large = try samplePhoto(bytes: WatchPhotoWire.maximumInlineBytes + 1)
        #expect(WatchPhotoWire.requiresFileTransfer(large))
        #expect(large.image.count <= WatchPhotoSendRequest.maximumImageBytes)
    }

    @Test func fileRefRoundTripsThroughTheWireMessage() throws {
        let photo = try samplePhoto(bytes: 32, caption: "look")
        let ref = try photo.fileRef(transferID: UUID())
        let encoded = try JSONEncoder().encode(WatchWireMessage.sendPhotoFile(ref))
        let decoded = try JSONDecoder().decode(WatchWireMessage.self, from: encoded)
        guard case .sendPhotoFile(let roundTripped) = decoded else {
            Issue.record("expected sendPhotoFile")
            return
        }
        #expect(roundTripped.filename == photo.filename)
        #expect(roundTripped.caption == "look")
        let rebuilt = try roundTripped.makeRequest(image: photo.image)
        #expect(rebuilt.image == photo.image)
        #expect(rebuilt.caption == "look")
    }

    @Test func rejectsPathFilenamesAndOversizeImages() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let session = try SessionKey(scope: scope, sessionID: "s1")
        #expect(throws: WatchPhotoValidationError.invalidFilename) {
            try WatchPhotoSendRequest(
                scope: scope,
                expectedRevision: Revision(1),
                session: session,
                filename: "../x.jpg",
                image: Data([0x1])
            )
        }
        #expect(throws: WatchPhotoValidationError.imageTooLarge) {
            try WatchPhotoSendRequest(
                scope: scope,
                expectedRevision: Revision(1),
                session: session,
                filename: "watch-photo.jpg",
                image: Data(repeating: 0x1, count: WatchPhotoSendRequest.maximumImageBytes + 1)
            )
        }
    }

    @Test func thumbnailFitsTheWatchFaceWireBudget() {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
            0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        let jpeg = WatchImageThumbnail.jpeg(from: png)
        #expect(jpeg != nil)
        #expect((jpeg?.count ?? .max) <= WatchImageThumbnail.watchFaceMaxBytes)
    }

    private func samplePhoto(bytes: Int, caption: String = "") throws -> WatchPhotoSendRequest {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        return try WatchPhotoSendRequest(
            scope: scope,
            expectedRevision: Revision(1),
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "watch-photo.jpg",
            image: Data(repeating: 0x1, count: bytes),
            caption: caption
        )
    }
}
