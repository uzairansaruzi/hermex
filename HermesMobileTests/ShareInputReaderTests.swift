import XCTest
import UniformTypeIdentifiers
@testable import HermesMobile

final class ShareInputReaderTests: XCTestCase {
    func testURLProviderVariantsLandInURLs() async {
        let providers = [
            NSItemProvider(item: URL(string: "https://example.com/a")! as NSURL, typeIdentifier: UTType.url.identifier),
            NSItemProvider(item: "https://example.com/b" as NSString, typeIdentifier: UTType.url.identifier),
            NSItemProvider(item: Data("https://example.com/c".utf8) as NSData, typeIdentifier: UTType.url.identifier)
        ]

        let input = await ShareInputReader.input(from: providers)

        XCTAssertEqual(
            input.urls.map(\.absoluteString),
            ["https://example.com/a", "https://example.com/b", "https://example.com/c"]
        )
        XCTAssertTrue(input.textSnippets.isEmpty)
        XCTAssertTrue(input.attachments.isEmpty)
    }

    func testURLStringsAreTrimmed() async {
        let provider = NSItemProvider(
            item: "  https://example.com/trim  " as NSString,
            typeIdentifier: UTType.url.identifier
        )

        let input = await ShareInputReader.input(from: [provider])

        XCTAssertEqual(input.urls.map(\.absoluteString), ["https://example.com/trim"])
    }

    func testFileURLIsRejectedFromURLs() async {
        let provider = NSItemProvider(
            item: URL(fileURLWithPath: "/tmp/example.txt") as NSURL,
            typeIdentifier: UTType.url.identifier
        )

        let input = await ShareInputReader.input(from: [provider])

        XCTAssertTrue(input.urls.isEmpty)
        XCTAssertTrue(input.attachments.isEmpty)
    }

    func testTextProviderVariantsLandInTextSnippets() async {
        let providers = [
            NSItemProvider(item: "plain string" as NSString, typeIdentifier: UTType.plainText.identifier),
            NSItemProvider(item: NSAttributedString(string: "attributed string"), typeIdentifier: UTType.plainText.identifier),
            NSItemProvider(item: Data("utf8 data".utf8) as NSData, typeIdentifier: UTType.plainText.identifier)
        ]

        let input = await ShareInputReader.input(from: providers)

        XCTAssertEqual(input.textSnippets, ["plain string", "attributed string", "utf8 data"])
        XCTAssertTrue(input.urls.isEmpty)
        XCTAssertTrue(input.attachments.isEmpty)
    }

    func testOversizedImageDataProducesNoAttachment() async {
        let oversized = Data(count: HermesShareDraft.maximumSharedAttachmentBytes + 1)
        let provider = NSItemProvider(item: oversized as NSData, typeIdentifier: UTType.png.identifier)

        let input = await ShareInputReader.input(from: [provider])

        XCTAssertTrue(input.attachments.isEmpty)
    }

    func testAttachmentsCappedAtSharedLimit() async {
        let providers = (0..<12).map { index in
            NSItemProvider(item: Data([UInt8(index)]) as NSData, typeIdentifier: UTType.png.identifier)
        }

        let input = await ShareInputReader.input(from: providers)

        XCTAssertEqual(input.attachments.count, HermesShareDraft.maximumSharedAttachmentCount)
        XCTAssertEqual(input.skipped, Array(repeating: SharedSkippedItem(filename: nil, reason: .overLimit), count: 2))
    }

    func testSkippedAttachmentsAreReportedWithTheirReasons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("notes.pdf")
        try Data("%PDF".utf8).write(to: pdfURL)
        let movieURL = directory.appendingPathComponent("big.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: movieURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: movieURL)
        try handle.truncate(atOffset: UInt64(HermesShareDraft.maximumSharedAttachmentBytes + 1))
        try handle.close()
        let emptyURL = directory.appendingPathComponent("empty.pdf")
        try Data().write(to: emptyURL)

        let clip = NSItemProvider(item: Data([1]) as NSData, typeIdentifier: UTType.mpeg4Movie.identifier)
        clip.suggestedName = "clip"
        let fallback = NSItemProvider(item: Data([2]) as NSData, typeIdentifier: UTType.png.identifier)
        fallback.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in
            completion?(directory.appendingPathComponent("gone.png") as NSURL, nil)
        }
        let providers = [
            NSItemProvider(item: pdfURL as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: movieURL as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: emptyURL as NSURL, typeIdentifier: UTType.fileURL.identifier),
            clip,
            fallback,
            NSItemProvider(item: "note" as NSString, typeIdentifier: UTType.plainText.identifier),
            NSItemProvider(item: URL(string: "https://example.com")! as NSURL, typeIdentifier: UTType.url.identifier)
        ]

        let input = await ShareInputReader.input(from: providers)

        XCTAssertEqual(input.attachments.map(\.filename), ["notes.pdf", "shared-image.png"])
        XCTAssertEqual(input.skipped, [
            SharedSkippedItem(filename: "big.mov", reason: .tooLarge),
            SharedSkippedItem(filename: "empty.pdf", reason: .unreadable),
            SharedSkippedItem(filename: "clip.mp4", reason: .unsupported)
        ])
    }

    func testFileURLAttachmentIsParsedFromTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("shared-note.txt")
        let payload = Data("file attachment bytes".utf8)
        try payload.write(to: fileURL)

        let provider = NSItemProvider(item: fileURL as NSURL, typeIdentifier: UTType.fileURL.identifier)

        let input = await ShareInputReader.input(from: [provider])

        XCTAssertTrue(input.urls.isEmpty, "a file:// URL must not leak into web urls")
        XCTAssertEqual(input.attachments.count, 1)
        XCTAssertEqual(input.attachments.first?.filename, "shared-note.txt")
        XCTAssertEqual(input.attachments.first?.data, payload)
        XCTAssertEqual(input.attachments.first?.typeIdentifier, UTType.plainText.identifier)
    }

    func testFileURLAttachmentIsMappedFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("scan.pdf")
        let payload = Data(repeating: 0x25, count: 1_024 * 1_024)
        try payload.write(to: fileURL)

        let provider = NSItemProvider(item: fileURL as NSURL, typeIdentifier: UTType.fileURL.identifier)

        let input = await ShareInputReader.input(from: [provider])

        let attachment = try XCTUnwrap(input.attachments.first)
        XCTAssertEqual(attachment.data, payload)
        XCTAssertTrue(isFileBacked(attachment.data), "file bytes must be mapped, not copied into memory")
    }

    func testImageFileRepresentationIsMappedFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("export.png")
        let payload = Data(repeating: 0x89, count: 1_024 * 1_024)
        try payload.write(to: fileURL)

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }

        let input = await ShareInputReader.input(from: [provider])

        let attachment = try XCTUnwrap(input.attachments.first)
        XCTAssertEqual(attachment.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(attachment.data, payload)
        XCTAssertTrue(isFileBacked(attachment.data), "provider bytes must be mapped, not copied into memory")
    }

    func testAttachmentFilenameUsesSuggestedName() async {
        let withoutExtension = NSItemProvider(item: Data([0x01]) as NSData, typeIdentifier: UTType.png.identifier)
        withoutExtension.suggestedName = "vacation"

        let withExtension = NSItemProvider(item: Data([0x02]) as NSData, typeIdentifier: UTType.png.identifier)
        withExtension.suggestedName = "vacation.png"

        let input = await ShareInputReader.input(from: [withoutExtension, withExtension])

        XCTAssertEqual(input.attachments.map(\.filename), ["vacation.png", "vacation.png"])
    }
}

func isFileBacked(_ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return false }
        let target = vm_address_t(UInt(bitPattern: base))
        var address = target
        var size: vm_size_t = 0
        var info = vm_region_extended_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_region_extended_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        var objectName: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO, $0, &count, &objectName)
            }
        }
        return result == KERN_SUCCESS && address <= target && info.external_pager != 0
    }
}
