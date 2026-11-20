import CoreGraphics
import Foundation
import ImageIO
import zlib

enum RFBFailure: Error, Equatable {
    case unsupportedVersion
    case refused
    case malformed
}

enum RFBOutput: Equatable {
    case send(Data)
    case updateComplete
}

enum RFBMessage {
    static let pixelFormat: Data = {
        var bytes: [UInt8] = [0, 0, 0, 0]
        bytes += [32, 24, 0, 1]
        bytes += [0, 255, 0, 255, 0, 255]
        bytes += [16, 8, 0, 0, 0, 0]
        return Data(bytes)
    }()

    static let encodings: Data = {
        let list: [Int32] = [7, 1, 0, -223, -25, -254]
        var data = Data([2, 0])
        data.appendBigEndian(UInt16(list.count))
        for encoding in list { data.appendBigEndian(UInt32(bitPattern: encoding)) }
        return data
    }()

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> Data {
        var data = Data([3, incremental ? 1 : 0])
        for value in [0, 0, width, height] { data.appendBigEndian(UInt16(value)) }
        return data
    }
}

final class RFBDecoder {
    private static let maximumSide = 8192
    private static let maximumCutText = 1 << 20

    private enum Stage {
        case version, securityTypes, securityResult, serverInit, message
        case rectangles(remaining: Int)
    }

    private struct NeedMoreBytes: Error {}

    private var stage = Stage.version
    private var bytes: [UInt8] = []
    private var head = 0
    private var cursor = 0
    private var framebuffer: RFBFramebuffer?
    private var inflaters: [RFBInflater?] = [nil, nil, nil, nil]
    private var needsFullUpdate = false
    private var isDirty = false

    var width: Int { framebuffer?.width ?? 0 }
    var height: Int { framebuffer?.height ?? 0 }

    func feed(_ chunk: Data) throws -> [RFBOutput] {
        bytes.append(contentsOf: chunk)
        var output: [RFBOutput] = []
        while head < bytes.count {
            cursor = head
            do {
                try step(&output)
                head = cursor
            } catch is NeedMoreBytes {
                break
            }
        }
        if head == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 1 << 16 {
            bytes.removeFirst(head)
            head = 0
        }
        return output
    }

    func updateRequest() -> Data {
        defer { needsFullUpdate = false }
        return RFBMessage.updateRequest(incremental: !needsFullUpdate, width: width, height: height)
    }

    func snapshot() -> CGImage? {
        guard isDirty else { return nil }
        isDirty = false
        return framebuffer?.image()
    }

    private func step(_ output: inout [RFBOutput]) throws {
        switch stage {
        case .version:
            let version = try read(12)
            guard version.starts(with: Array("RFB 003.".utf8)), version[version.startIndex + 11] == 0x0A,
                  let minor = Int(String(decoding: version[(version.startIndex + 8)..<(version.startIndex + 11)], as: UTF8.self)),
                  minor >= 7
            else { throw RFBFailure.unsupportedVersion }
            output.append(.send(Data("RFB 003.008\n".utf8)))
            stage = .securityTypes
        case .securityTypes:
            let count = Int(try readByte())
            let types = try read(count)
            guard types.contains(1) else { throw RFBFailure.refused }
            output.append(.send(Data([1])))
            stage = .securityResult
        case .securityResult:
            guard try readUInt32() == 0 else { throw RFBFailure.refused }
            output.append(.send(Data([1])))
            stage = .serverInit
        case .serverInit:
            let width = Int(try readUInt16()), height = Int(try readUInt16())
            _ = try read(16)
            let nameLength = Int(try readUInt32())
            guard nameLength <= 4096 else { throw RFBFailure.malformed }
            _ = try read(nameLength)
            framebuffer = try makeFramebuffer(width: width, height: height)
            output.append(.send(RFBMessage.pixelFormat))
            output.append(.send(RFBMessage.encodings))
            output.append(.send(RFBMessage.updateRequest(incremental: false, width: width, height: height)))
            stage = .message
        case .message:
            try readMessage(&output)
        case .rectangles(let remaining):
            try readRectangle()
            if remaining > 1 {
                stage = .rectangles(remaining: remaining - 1)
            } else {
                stage = .message
                output.append(.updateComplete)
            }
        }
    }

    private func readMessage(_ output: inout [RFBOutput]) throws {
        switch try readByte() {
        case 0:
            _ = try readByte()
            let count = Int(try readUInt16())
            if count == 0 {
                output.append(.updateComplete)
            } else {
                stage = .rectangles(remaining: count)
            }
        case 2:
            break
        case 3:
            _ = try read(3)
            let length = Int(try readUInt32())
            guard length <= Self.maximumCutText else { throw RFBFailure.malformed }
            _ = try read(length)
        default:
            throw RFBFailure.malformed
        }
    }

    private func readRectangle() throws {
        let x = Int(try readUInt16()), y = Int(try readUInt16())
        let width = Int(try readUInt16()), height = Int(try readUInt16())
        let encoding = Int32(bitPattern: try readUInt32())
        if encoding == -223 {
            framebuffer = try makeFramebuffer(width: width, height: height)
            needsFullUpdate = true
            isDirty = true
            return
        }
        guard let framebuffer else { throw RFBFailure.malformed }
        let rect = RFBRect(x: x, y: y, width: width, height: height)
        guard framebuffer.contains(rect) else { throw RFBFailure.malformed }
        switch encoding {
        case 0:
            try readRaw(rect, into: framebuffer)
        case 1:
            let sourceX = Int(try readUInt16()), sourceY = Int(try readUInt16())
            let source = RFBRect(x: sourceX, y: sourceY, width: width, height: height)
            guard framebuffer.contains(source) else { throw RFBFailure.malformed }
            framebuffer.copy(from: source, to: rect)
        case 7:
            try readTight(rect, into: framebuffer)
        default:
            throw RFBFailure.malformed
        }
        isDirty = true
    }

    private func readRaw(_ rect: RFBRect, into framebuffer: RFBFramebuffer) throws {
        let pixels = try read(rect.width * rect.height * 4)
        pixels.withUnsafeBufferPointer { framebuffer.writeBGRX($0, to: rect) }
    }

    private func readTight(_ rect: RFBRect, into framebuffer: RFBFramebuffer) throws {
        let control = try readByte()
        let kind = control >> 4
        switch kind {
        case 0b1000:
            let color = try read(3)
            resetStreams(control)
            framebuffer.fill(rect, red: color[color.startIndex], green: color[color.startIndex + 1], blue: color[color.startIndex + 2])
        case 0b1001:
            let length = try readCompactLength()
            let jpeg = try read(length)
            resetStreams(control)
            try jpeg.withUnsafeBufferPointer { try framebuffer.drawJPEG($0, in: rect) }
        default:
            guard kind & 0b1000 == 0 else { throw RFBFailure.malformed }
            let filter = kind & 0b0100 != 0 ? try readByte() : 0
            let stream = Int(kind & 0b0011)
            switch filter {
            case 0:
                let data = try readTightData(size: rect.width * rect.height * 3, stream: stream, control: control)
                data.withUnsafeBufferPointer { framebuffer.writeRGB($0, to: rect) }
            case 1:
                let colors = Int(try readByte()) + 1
                let palette = try read(colors * 3)
                let rowBytes = colors <= 2 ? (rect.width + 7) / 8 : rect.width
                let data = try readTightData(size: rowBytes * rect.height, stream: stream, control: control)
                try data.withUnsafeBufferPointer { indices in
                    try palette.withUnsafeBufferPointer { palette in
                        try framebuffer.writePalette(indices, palette: palette, colors: colors, to: rect)
                    }
                }
            case 2:
                let data = try readTightData(size: rect.width * rect.height * 3, stream: stream, control: control)
                data.withUnsafeBufferPointer { framebuffer.writeGradient($0, to: rect) }
            default:
                throw RFBFailure.malformed
            }
        }
    }

    private func readTightData(size: Int, stream: Int, control: UInt8) throws -> ArraySlice<UInt8> {
        guard size >= 12 else {
            let data = try read(size)
            resetStreams(control)
            return data
        }
        let length = try readCompactLength()
        let compressed = try read(length)
        resetStreams(control)
        let inflater = try inflater(stream)
        return ArraySlice(try compressed.withUnsafeBufferPointer { try inflater.inflate($0, size: size) })
    }

    private func resetStreams(_ control: UInt8) {
        for index in 0..<4 where control & (1 << UInt8(index)) != 0 {
            inflaters[index]?.reset()
        }
    }

    private func inflater(_ stream: Int) throws -> RFBInflater {
        if let existing = inflaters[stream] { return existing }
        let created = try RFBInflater()
        inflaters[stream] = created
        return created
    }

    private func readCompactLength() throws -> Int {
        var length = 0
        for shift in [0, 7, 14] {
            let byte = try readByte()
            if shift == 14 {
                return length | Int(byte) << shift
            }
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
        }
        return length
    }

    private func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard bytes.count - cursor >= count else { throw NeedMoreBytes() }
        defer { cursor += count }
        return bytes[cursor..<(cursor + count)]
    }

    private func readByte() throws -> UInt8 {
        guard cursor < bytes.count else { throw NeedMoreBytes() }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    private func readUInt16() throws -> UInt16 {
        let value = try read(2)
        return UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1])
    }

    private func readUInt32() throws -> UInt32 {
        let value = try read(4)
        return value.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func makeFramebuffer(width: Int, height: Int) throws -> RFBFramebuffer {
        guard (1...Self.maximumSide).contains(width), (1...Self.maximumSide).contains(height),
              let framebuffer = RFBFramebuffer(width: width, height: height)
        else { throw RFBFailure.malformed }
        return framebuffer
    }
}

struct RFBRect: Equatable {
    let x, y, width, height: Int
}

private final class RFBInflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init() throws {
        stream.initialize(to: z_stream())
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deallocate()
            throw RFBFailure.malformed
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    func reset() {
        inflateReset(stream)
    }

    func inflate(_ input: UnsafeBufferPointer<UInt8>, size: Int) throws -> [UInt8] {
        guard let base = input.baseAddress else { throw RFBFailure.malformed }
        return try [UInt8](unsafeUninitializedCapacity: size) { output, count in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: base)
            stream.pointee.avail_in = UInt32(input.count)
            stream.pointee.next_out = output.baseAddress
            stream.pointee.avail_out = UInt32(size)
            while stream.pointee.avail_out > 0 {
                let status = zlib.inflate(stream, Z_SYNC_FLUSH)
                if status == Z_BUF_ERROR { break }
                guard status == Z_OK else { throw RFBFailure.malformed }
            }
            guard stream.pointee.avail_out == 0 else { throw RFBFailure.malformed }
            try drain()
            count = size
        }
    }

    private func drain() throws {
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        while stream.pointee.avail_in > 0 {
            stream.pointee.next_out = scratch
            stream.pointee.avail_out = 1
            let status = zlib.inflate(stream, Z_SYNC_FLUSH)
            guard status == Z_OK, stream.pointee.avail_out == 1 else { throw RFBFailure.malformed }
        }
    }
}

private final class RFBFramebuffer {
    let width, height: Int
    private let pixels: UnsafeMutablePointer<UInt32>
    private let context: CGContext
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0xFF00_0000, count: width * height)
        guard let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: Self.bitmapInfo.rawValue)
        else {
            pixels.deallocate()
            return nil
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        self.context = context
    }

    deinit {
        pixels.deallocate()
    }

    func contains(_ rect: RFBRect) -> Bool {
        rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    func image() -> CGImage? {
        let copy = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: context.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func fill(_ rect: RFBRect, red: UInt8, green: UInt8, blue: UInt8) {
        let color = Self.pixel(red, green, blue)
        forEachRow(rect) { row in
            row.update(repeating: color, count: rect.width)
        }
    }

    func writeBGRX(_ source: UnsafeBufferPointer<UInt8>, to rect: RFBRect) {
        guard let base = source.baseAddress else { return }
        var offset = 0
        forEachRow(rect) { row in
            memcpy(row, base + offset, rect.width * 4)
            for index in 0..<rect.width { row[index] |= 0xFF00_0000 }
            offset += rect.width * 4
        }
    }

    func writeRGB(_ source: UnsafeBufferPointer<UInt8>, to rect: RFBRect) {
        var offset = 0
        forEachRow(rect) { row in
            for index in 0..<rect.width {
                row[index] = Self.pixel(source[offset], source[offset + 1], source[offset + 2])
                offset += 3
            }
        }
    }

    func writePalette(_ indices: UnsafeBufferPointer<UInt8>, palette: UnsafeBufferPointer<UInt8>, colors: Int,
                      to rect: RFBRect) throws {
        var table = [UInt32](repeating: 0, count: colors)
        for color in 0..<colors {
            table[color] = Self.pixel(palette[color * 3], palette[color * 3 + 1], palette[color * 3 + 2])
        }
        var failed = false
        var rowStart = 0
        let rowBytes = colors <= 2 ? (rect.width + 7) / 8 : rect.width
        forEachRow(rect) { row in
            for column in 0..<rect.width {
                let index: Int
                if colors <= 2 {
                    index = Int(indices[rowStart + column / 8] >> UInt8(7 - column % 8)) & 1
                } else {
                    index = Int(indices[rowStart + column])
                }
                if index < colors { row[column] = table[index] } else { failed = true }
            }
            rowStart += rowBytes
        }
        if failed { throw RFBFailure.malformed }
    }

    func writeGradient(_ source: UnsafeBufferPointer<UInt8>, to rect: RFBRect) {
        var previous = [UInt8](repeating: 0, count: rect.width * 3)
        var current = [UInt8](repeating: 0, count: rect.width * 3)
        var offset = 0
        forEachRow(rect) { row in
            for column in 0..<rect.width {
                for channel in 0..<3 {
                    let index = column * 3 + channel
                    let left = column > 0 ? Int(current[index - 3]) : 0
                    let aboveLeft = column > 0 ? Int(previous[index - 3]) : 0
                    let prediction = max(0, min(255, left + Int(previous[index]) - aboveLeft))
                    current[index] = UInt8(truncatingIfNeeded: prediction + Int(source[offset]))
                    offset += 1
                }
                let start = column * 3
                row[column] = Self.pixel(current[start], current[start + 1], current[start + 2])
            }
            swap(&previous, &current)
        }
    }

    func copy(from source: RFBRect, to destination: RFBRect) {
        let rows = Array(0..<destination.height)
        for row in source.y < destination.y ? rows.reversed() : rows {
            memmove(pixels + (destination.y + row) * width + destination.x,
                    pixels + (source.y + row) * width + source.x,
                    destination.width * 4)
        }
    }

    func drawJPEG(_ jpeg: UnsafeBufferPointer<UInt8>, in rect: RFBRect) throws {
        let data = Data(buffer: jpeg)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == rect.width, image.height == rect.height
        else { throw RFBFailure.malformed }
        context.draw(image, in: CGRect(x: rect.x, y: height - rect.y - rect.height, width: rect.width, height: rect.height))
    }

    private func forEachRow(_ rect: RFBRect, _ body: (UnsafeMutablePointer<UInt32>) -> Void) {
        for row in 0..<rect.height {
            body(pixels + (rect.y + row) * width + rect.x)
        }
    }

    private static func pixel(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in [24, 16, 8, 0] { append(UInt8(value >> UInt32(shift) & 0xFF)) }
    }
}
