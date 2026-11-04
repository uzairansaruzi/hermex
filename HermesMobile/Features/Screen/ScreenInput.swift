import Foundation

/// A key the screen understands, as an X keysym: what RFB's KeyEvent carries whatever the host is.
struct ScreenKey: Hashable, Sendable {
    let keysym: UInt32

    static let escape = ScreenKey(keysym: 0xFF1B)
    static let tab = ScreenKey(keysym: 0xFF09)
    static let enter = ScreenKey(keysym: 0xFF0D)
    static let backspace = ScreenKey(keysym: 0xFF08)
    static let delete = ScreenKey(keysym: 0xFFFF)
    static let left = ScreenKey(keysym: 0xFF51)
    static let up = ScreenKey(keysym: 0xFF52)
    static let right = ScreenKey(keysym: 0xFF53)
    static let down = ScreenKey(keysym: 0xFF54)
    static let home = ScreenKey(keysym: 0xFF50)
    static let end = ScreenKey(keysym: 0xFF57)
    static let pageUp = ScreenKey(keysym: 0xFF55)
    static let pageDown = ScreenKey(keysym: 0xFF56)
    static let shift = ScreenKey(keysym: 0xFFE1)
    static let control = ScreenKey(keysym: 0xFFE3)
    static let option = ScreenKey(keysym: 0xFFE9)
    static let command = ScreenKey(keysym: 0xFFEB)

    static func function(_ number: Int) -> ScreenKey { ScreenKey(keysym: 0xFFBE + UInt32(number) - 1) }

    /// One typed scalar: Latin-1 as itself, anything else in the Unicode keysym range. Line
    /// breaks and tabs are the keys that make them. A control character has no key: nil.
    init?(typing scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x0A, 0x0D: self = .enter
        case 0x09: self = .tab
        case 0x20...0x7E, 0xA0...0xFF: keysym = scalar.value
        case 0x100...: keysym = 0x0100_0000 | scalar.value
        default: return nil
        }
    }

    init(keysym: UInt32) { self.keysym = keysym }
}

/// RFB's input messages, in the bytes the server's filter frames.
extension RFBMessage {
    /// The bit each button has in a PointerEvent's mask.
    enum Button {
        static let left: UInt8 = 1
        static let right: UInt8 = 1 << 2
        static let wheelUp: UInt8 = 1 << 3
        static let wheelDown: UInt8 = 1 << 4
    }

    static func pointer(x: Int, y: Int, buttons: UInt8) -> Data {
        Data([5, buttons, UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF), UInt8(y >> 8 & 0xFF), UInt8(y & 0xFF)])
    }

    static func key(_ key: ScreenKey, down: Bool) -> Data {
        let symbol = key.keysym
        return Data([4, down ? 1 : 0, 0, 0, UInt8(symbol >> 24), UInt8(symbol >> 16 & 0xFF), UInt8(symbol >> 8 & 0xFF), UInt8(symbol & 0xFF)])
    }
}

/// Input waiting for the socket, in order. A pointer move replaces a move still waiting with the
/// same buttons, and whatever piled up during a send goes out as one frame, so a fast finger on a
/// slow link falls behind by one position rather than by a queue. Keys and clicks are never dropped.
struct ScreenInputQueue {
    private enum Item {
        case pointer(x: Int, y: Int, buttons: UInt8)
        case other(Data)
    }

    private var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func movePointer(x: Int, y: Int, buttons: UInt8) {
        if case .pointer(_, _, buttons)? = items.last { items.removeLast() }
        items.append(.pointer(x: x, y: y, buttons: buttons))
    }

    /// A click or key, which must keep its place after the moves before it.
    mutating func append(_ message: Data) {
        items.append(.other(message))
    }

    mutating func drain() -> Data {
        defer { items.removeAll(keepingCapacity: true) }
        return items.reduce(into: Data()) { data, item in
            switch item {
            case .pointer(let x, let y, let buttons): data.append(RFBMessage.pointer(x: x, y: y, buttons: buttons))
            case .other(let message): data.append(message)
            }
        }
    }
}

/// What a picture point means on the screen: `point` in a view `viewSize` big showing all of a
/// `width` by `height` framebuffer, as a framebuffer pixel, kept on the picture.
func screenPixel(at point: CGPoint, in viewSize: CGSize, width: Int, height: Int) -> (x: Int, y: Int)? {
    guard viewSize.width > 0, viewSize.height > 0, width > 0, height > 0 else { return nil }
    let x = Int(point.x / viewSize.width * CGFloat(width))
    let y = Int(point.y / viewSize.height * CGFloat(height))
    return (min(max(x, 0), width - 1), min(max(y, 0), height - 1))
}
