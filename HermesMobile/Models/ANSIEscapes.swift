import Foundation

// Cron run transcripts arrive with the shell's terminal control bytes intact
// (`\u{1b}[0;32m`). SwiftUI has no notion of them and renders the raw bytes as
// garbage, so every surface that shows server-supplied run text — the Tasks
// row, Task Detail's error line, the recent-run output — puts it through
// `strippingANSIEscapes()` first.
extension String {
    /// Returns the string with ANSI/VT escape sequences removed.
    ///
    /// Recognises CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC \`) and the
    /// two-character escapes. A sequence that never terminates — the normal
    /// result of a transcript truncated mid-escape — is dropped through the end
    /// of the string rather than leaking its bytes into the UI.
    func strippingANSIEscapes() -> String {
        guard unicodeScalars.contains("\u{1B}") else { return self }

        let scalars = Array(unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { break }

            switch scalars[index] {
            case "[":
                // CSI: parameter and intermediate bytes, then one final byte.
                index += 1
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    index += 1
                }
                if index < scalars.count { index += 1 }
            case "]":
                // OSC: runs until BEL or the string terminator `ESC \`.
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\u{07}" {
                        index += 1
                        break
                    }
                    if scalars[index] == "\u{1B}",
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }

        return String(output)
    }

    /// The first meaningful line of a multi-line server transcript, escapes
    /// stripped and clipped, for places that have room for one line only. The
    /// full text stays reachable on Task Detail.
    func firstLineSummary(limit: Int = 120) -> String? {
        let stripped = strippingANSIEscapes()
        guard let line = stripped
            .split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        guard line.count > limit else { return line }
        return line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
