import Foundation

public enum WatchPhotoValidationError: Error, Equatable, Sendable {
    case invalidFilename
    case imageTooLarge
    case imageEmpty
    case scopeMismatch
}

/// WatchConnectivity `sendMessage` budget is the same as voice notes. Photos
/// almost always exceed it after JPEG encoding, so they travel through
/// `WCSession.transferFile`.
public enum WatchPhotoWire: Sendable {
    public static let maximumInlineBytes = WatchVoiceNoteWire.maximumInlineAudioBytes
    public static let fileTransferMetadataKey = "hermexPhotoTransferID"

    public static func requiresFileTransfer(_ request: WatchPhotoSendRequest) -> Bool {
        request.image.count > maximumInlineBytes
    }
}

public struct WatchPhotoSendRequest: Hashable, Codable, Sendable {
    public static let maximumImageBytes = WatchImageThumbnail.sendMaxBytes

    public let scope: ServerScope
    public let expectedRevision: Revision
    public let session: SessionKey
    public let filename: String
    public let image: Data
    public let caption: String

    public init(
        scope: ServerScope,
        expectedRevision: Revision,
        session: SessionKey,
        filename: String,
        image: Data,
        caption: String = ""
    ) throws {
        try WatchPhotoFilename.validate(filename)
        guard session.scope == scope else { throw WatchPhotoValidationError.scopeMismatch }
        guard !image.isEmpty else { throw WatchPhotoValidationError.imageEmpty }
        guard image.count <= Self.maximumImageBytes else { throw WatchPhotoValidationError.imageTooLarge }
        self.scope = scope
        self.expectedRevision = expectedRevision
        self.session = session
        self.filename = filename
        self.image = image
        self.caption = caption
    }

    public func fileRef(transferID: UUID) throws -> WatchPhotoFileRef {
        try WatchPhotoFileRef(
            transferID: transferID,
            scope: scope,
            expectedRevision: expectedRevision,
            session: session,
            filename: filename,
            imageByteCount: image.count,
            caption: caption
        )
    }
}

public struct WatchPhotoFileRef: Hashable, Codable, Sendable {
    public let transferID: UUID
    public let scope: ServerScope
    public let expectedRevision: Revision
    public let session: SessionKey
    public let filename: String
    public let imageByteCount: Int
    public let caption: String

    public init(
        transferID: UUID,
        scope: ServerScope,
        expectedRevision: Revision,
        session: SessionKey,
        filename: String,
        imageByteCount: Int,
        caption: String
    ) throws {
        try WatchPhotoFilename.validate(filename)
        guard session.scope == scope else { throw WatchPhotoValidationError.scopeMismatch }
        guard imageByteCount > 0 else { throw WatchPhotoValidationError.imageEmpty }
        guard imageByteCount <= WatchPhotoSendRequest.maximumImageBytes else {
            throw WatchPhotoValidationError.imageTooLarge
        }
        self.transferID = transferID
        self.scope = scope
        self.expectedRevision = expectedRevision
        self.session = session
        self.filename = filename
        self.imageByteCount = imageByteCount
        self.caption = caption
    }

    public func makeRequest(image: Data) throws -> WatchPhotoSendRequest {
        try WatchPhotoSendRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            session: session,
            filename: filename,
            image: image,
            caption: caption
        )
    }
}

enum WatchPhotoFilename {
    static func validate(_ filename: String) throws {
        let allowed = filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") || filename.hasSuffix(".png")
        guard allowed,
              filename.utf8.count <= 128,
              !filename.contains(".."),
              !filename.contains("/")
        else {
            throw WatchPhotoValidationError.invalidFilename
        }
    }
}
