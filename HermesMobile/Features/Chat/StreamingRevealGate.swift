import Foundation

/// Decides how much buffered assistant text one streaming reveal tick shows (#1126).
///
/// There is no display pacing: a tick shows everything buffered up to the last
/// whitespace, so the screen never trails received text by more than one tick.
/// The trailing partial word is held back so a word never appears half-typed,
/// but only for one tick: if the previous tick held a fragment and no whitespace
/// has arrived since, the whole buffer is released, so CJK text, long URLs and
/// code never stall. Splitting walks `Character`s, so grapheme clusters are never
/// split, and `shown + held` always reproduces the buffer exactly.
enum StreamingRevealGate {
    /// Splits `pending` into the text to show now and the fragment to keep
    /// buffered. `heldPreviousTick` is whether the previous tick returned a
    /// non-empty `held`.
    static func cut(_ pending: String, heldPreviousTick: Bool) -> (shown: String, held: String) {
        guard let lastWhitespace = pending.lastIndex(where: \.isWhitespace) else {
            return heldPreviousTick ? (pending, "") : ("", pending)
        }
        let boundary = pending.index(after: lastWhitespace)
        return (String(pending[..<boundary]), String(pending[boundary...]))
    }
}
