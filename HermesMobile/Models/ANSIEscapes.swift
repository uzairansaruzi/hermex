import Foundation

extension String {
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
                index += 1
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    index += 1
                }
                if index < scalars.count { index += 1 }
            case "]":
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
