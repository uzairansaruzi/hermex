import Foundation

public enum HermexSSEEvent: Equatable, Sendable {
    case token(String)
    case usage(String)
    case done(String?)
    case error(String)
    case named(event: String, data: String)
}

public struct HermexSSEDecoder: Sendable {
    public init() {}

    public func decode(block: String) -> HermexSSEEvent? {
        var eventName: String?
        var dataLines: [String] = []

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: CharacterSet.newlines)
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: CharacterSet.whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: CharacterSet.whitespaces))
            }
        }

        guard !dataLines.isEmpty else {
            return nil
        }

        let data = dataLines.joined(separator: "\n")
        switch eventName {
        case nil, "message", "token":
            return .token(data)
        case "usage":
            return .usage(data)
        case "done":
            return .done(data.isEmpty ? nil : data)
        case "error":
            return .error(data)
        case let name?:
            return .named(event: name, data: data)
        }
    }
}
