import Foundation

enum StreamingRevealGate {
    static func cut(_ pending: String, heldPreviousTick: Bool) -> (shown: String, held: String) {
        guard let lastWhitespace = pending.lastIndex(where: \.isWhitespace) else {
            return heldPreviousTick ? (pending, "") : ("", pending)
        }
        let boundary = pending.index(after: lastWhitespace)
        return (String(pending[..<boundary]), String(pending[boundary...]))
    }
}
