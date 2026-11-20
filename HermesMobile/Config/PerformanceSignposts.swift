import OSLog

let performanceSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "Performance"
)

@MainActor
enum LaunchSignpost {
    private static var state: OSSignpostIntervalState?
    private static var ended = false

    static func begin() {
        state = performanceSignposter.beginInterval("Launch", id: performanceSignposter.makeSignpostID())
    }

    static func end(rows: Int) {
        guard !ended, rows > 0, let state else { return }
        ended = true
        DispatchQueue.main.async {
            performanceSignposter.endInterval("Launch", state, "rows=\(rows, privacy: .public)")
        }
    }
}

@MainActor
enum SessionOpenSignpost {
    private static var pending: (sessionID: String, state: OSSignpostIntervalState)?

    static func begin(sessionID: String?) {
        if let pending {
            performanceSignposter.endInterval("Session Open", pending.state)
            self.pending = nil
        }
        guard let sessionID else { return }
        let state = performanceSignposter.beginInterval("Session Open", id: performanceSignposter.makeSignpostID())
        pending = (sessionID, state)
    }

    static func end(sessionID: String?, messages: Int?) {
        guard let pending, pending.sessionID == sessionID else { return }
        self.pending = nil
        if let messages {
            performanceSignposter.endInterval("Session Open", pending.state, "messages=\(messages, privacy: .public)")
        } else {
            performanceSignposter.endInterval("Session Open", pending.state)
        }
    }
}
