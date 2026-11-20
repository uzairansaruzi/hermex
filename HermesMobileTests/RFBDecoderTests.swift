import CoreGraphics
import XCTest
import zlib
@testable import HermesMobile

final class RFBDecoderTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Screen/busy-tight.bin")

    func testARecordedScreenDecodesTheSameAtAnyChunkBoundary() throws {
        guard let recorded = try? Data(contentsOf: Self.fixture) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        var pictures: [Data] = []
        for size in [recorded.count, 65_536, 1_021, 7] {
            let decoder = RFBDecoder()
            var updates = 0
            var offset = 0
            while offset < recorded.count {
                let chunk = recorded.subdata(in: offset..<min(offset + size, recorded.count))
                offset += chunk.count
                updates += try decoder.feed(chunk).filter { $0 == .updateComplete }.count
            }
            XCTAssertEqual(updates, 2)
            XCTAssertEqual(decoder.width, 1440)
            XCTAssertEqual(decoder.height, 900)
            pictures.append(try XCTUnwrap(pixels(try XCTUnwrap(decoder.snapshot()))))
        }
        XCTAssertEqual(Set(pictures).count, 1)
        let colors = Set(stride(from: 0, to: pictures[0].count, by: 4).map { pictures[0][$0] })
        XCTAssertGreaterThan(colors.count, 32, "a busy screen, not a flat one")
    }

    func testTheHandshakeSendsWhatTheServerFilterExpects() throws {
        let decoder = RFBDecoder()
        var sent = try sends(decoder.feed(Data("RFB 003.008\n".utf8)))
        sent += try sends(decoder.feed(Data([1, 1])))
        sent += try sends(decoder.feed(Data([0, 0, 0, 0])))
        XCTAssertEqual(sent.map(\.count), [12, 1, 1])
        XCTAssertEqual(sent.last, Data([1]), "shared")

        sent = try sends(decoder.feed(serverInit(width: 4, height: 2)))
        XCTAssertEqual(sent.map { $0.first }, [0, 2, 3], "SetPixelFormat, SetEncodings, FramebufferUpdateRequest")
        XCTAssertEqual(Array(sent[0]).count, 20)
        XCTAssertEqual(sent[2], RFBMessage.updateRequest(incremental: false, width: 4, height: 2))
    }

    func testAServerWithoutSecurityTypeNoneIsRefused() throws {
        let decoder = RFBDecoder()
        _ = try decoder.feed(Data("RFB 003.008\n".utf8))
        XCTAssertThrowsError(try decoder.feed(Data([1, 2]))) { XCTAssertEqual($0 as? RFBFailure, .refused) }
    }

    func testTightFillAndUncompressedDataDrawExactPixels() throws {
        let decoder = try ready(width: 2, height: 2)
        var stream = update(rectangles: 2)
        stream += rectangleHeader(x: 0, y: 0, width: 2, height: 1, encoding: 7) + [0x80, 10, 20, 30]
        stream += rectangleHeader(x: 0, y: 1, width: 2, height: 1, encoding: 7) + [0x00, 1, 2, 3, 4, 5, 6]
        _ = try decoder.feed(Data(stream))
        XCTAssertEqual(try rgb(decoder), [[10, 20, 30], [10, 20, 30], [1, 2, 3], [4, 5, 6]])
    }

    func testAPersistentZlibStreamCarriesAcrossRectanglesUntilReset() throws {
        let decoder = try ready(width: 4, height: 4)
        var deflater = Deflater()
        let red = Array(repeating: [UInt8]([200, 0, 0]), count: 8).flatMap { $0 }
        let green = Array(repeating: [UInt8]([0, 200, 0]), count: 8).flatMap { $0 }
        var stream = update(rectangles: 3)
        stream += rectangleHeader(x: 0, y: 0, width: 4, height: 2, encoding: 7) + [0x00] + compact(deflater.deflate(red))
        stream += rectangleHeader(x: 0, y: 2, width: 4, height: 2, encoding: 7) + [0x00] + compact(deflater.deflate(green))
        var fresh = Deflater()
        stream += rectangleHeader(x: 0, y: 0, width: 4, height: 2, encoding: 7) + [0x01] + compact(fresh.deflate(green))
        for byte in stream { _ = try decoder.feed(Data([byte])) }
        XCTAssertEqual(try rgb(decoder), Array(repeating: [0, 200, 0], count: 16))
    }

    func testTightPaletteAndGradientFiltersDrawExactPixels() throws {
        let decoder = try ready(width: 3, height: 2)
        var stream = update(rectangles: 1)
        stream += rectangleHeader(x: 0, y: 0, width: 3, height: 2, encoding: 7) + [0x40, 1, 1, 9, 9, 9, 7, 7, 7, 0b1010_0000, 0b0100_0000]
        _ = try decoder.feed(Data(stream))
        XCTAssertEqual(try rgb(decoder), [[7, 7, 7], [9, 9, 9], [7, 7, 7], [9, 9, 9], [7, 7, 7], [9, 9, 9]])

        stream = update(rectangles: 1)
        stream += rectangleHeader(x: 0, y: 0, width: 3, height: 1, encoding: 7) + [0x40, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3, 2, 0, 1]
        _ = try decoder.feed(Data(stream))
        XCTAssertEqual(try rgb(decoder).prefix(3), [[3, 3, 3], [1, 1, 1], [2, 2, 2]])

        let gradient: [UInt8] = [10, 0, 0,  5, 0, 0,  1, 0, 0,  2, 0, 0]
        var deflater = Deflater()
        stream = update(rectangles: 1)
        stream += rectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: 7) + [0x40, 2] + compact(deflater.deflate(gradient))
        _ = try decoder.feed(Data(stream))
        let reds = try rgb(decoder).map { $0[0] }
        XCTAssertEqual(Array(reds[0...1]), [10, 15])
        XCTAssertEqual(Array(reds[3...4]), [11, 18])
    }

    func testCopyRectKeepsAnOverlappingSourceIntact() throws {
        let decoder = try ready(width: 3, height: 1)
        var stream = update(rectangles: 2)
        stream += rectangleHeader(x: 0, y: 0, width: 3, height: 1, encoding: 0)
        stream += [3, 0, 0, 0,  2, 0, 0, 0,  1, 0, 0, 0]
        stream += rectangleHeader(x: 1, y: 0, width: 2, height: 1, encoding: 1) + [0, 0, 0, 0]
        _ = try decoder.feed(Data(stream))
        XCTAssertEqual(try rgb(decoder), [[0, 0, 3], [0, 0, 3], [0, 0, 2]])
    }

    func testADesktopSizeRectangleAsksForTheWholeNewPicture() throws {
        let decoder = try ready(width: 2, height: 2)
        _ = try decoder.feed(Data(update(rectangles: 1) + rectangleHeader(x: 0, y: 0, width: 5, height: 3, encoding: -223)))
        XCTAssertEqual(decoder.width, 5)
        XCTAssertEqual(decoder.updateRequest(), RFBMessage.updateRequest(incremental: false, width: 5, height: 3))
        XCTAssertEqual(decoder.updateRequest(), RFBMessage.updateRequest(incremental: true, width: 5, height: 3))
    }

    func testABrokenStreamFailsRatherThanDrawingOutOfBounds() throws {
        let outside = try ready(width: 2, height: 2)
        XCTAssertThrowsError(try outside.feed(Data(update(rectangles: 1) + rectangleHeader(x: 1, y: 1, width: 2, height: 2, encoding: 7) + [0x80, 0, 0, 0]))) {
            XCTAssertEqual($0 as? RFBFailure, .malformed)
        }
        let source = try ready(width: 2, height: 2)
        XCTAssertThrowsError(try source.feed(Data(update(rectangles: 1) + rectangleHeader(x: 0, y: 0, width: 1, height: 1, encoding: 1) + [0, 9, 0, 9]))) {
            XCTAssertEqual($0 as? RFBFailure, .malformed)
        }
        let index = try ready(width: 1, height: 1)
        XCTAssertThrowsError(try index.feed(Data(update(rectangles: 1) + rectangleHeader(x: 0, y: 0, width: 1, height: 1, encoding: 7) + [0x40, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3]))) {
            XCTAssertEqual($0 as? RFBFailure, .malformed)
        }
        let unknown = try ready(width: 2, height: 2)
        XCTAssertThrowsError(try unknown.feed(Data([99]))) { XCTAssertEqual($0 as? RFBFailure, .malformed) }
    }

    private func ready(width: Int, height: Int) throws -> RFBDecoder {
        let decoder = RFBDecoder()
        _ = try decoder.feed(Data("RFB 003.008\n".utf8) + Data([1, 1, 0, 0, 0, 0]) + serverInit(width: width, height: height))
        return decoder
    }

    private func serverInit(width: Int, height: Int) -> Data {
        var bytes = uint16(width) + uint16(height)
        bytes += [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        bytes += [0, 0, 0, 1, 0x78]
        return Data(bytes)
    }

    private func update(rectangles: Int) -> [UInt8] { [0, 0] + uint16(rectangles) }

    private func rectangleHeader(x: Int, y: Int, width: Int, height: Int, encoding: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: encoding)
        return uint16(x) + uint16(y) + uint16(width) + uint16(height)
            + [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    private func uint16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    private func compact(_ data: [UInt8]) -> [UInt8] {
        var length = data.count
        var out: [UInt8] = []
        while length > 0x7F {
            out.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        out.append(UInt8(length))
        return out + data
    }

    private func sends(_ output: [RFBOutput]) -> [Data] {
        output.compactMap { if case .send(let data) = $0 { data } else { nil } }
    }

    private func pixels(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

    private func rgb(_ decoder: RFBDecoder) throws -> [[UInt8]] {
        let data = try XCTUnwrap(pixels(try XCTUnwrap(decoder.snapshot())))
        return stride(from: 0, to: data.count, by: 4).map { [data[$0 + 2], data[$0 + 1], data[$0]] }
    }
}

private struct Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    mutating func deflate(_ input: [UInt8]) -> [UInt8] {
        var input = input
        var output = [UInt8](repeating: 0, count: input.count + 256)
        let produced = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.pointee.next_in = source.baseAddress
                stream.pointee.avail_in = UInt32(source.count)
                stream.pointee.next_out = target.baseAddress
                stream.pointee.avail_out = UInt32(target.count)
                zlib.deflate(stream, Z_SYNC_FLUSH)
                return target.count - Int(stream.pointee.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}
