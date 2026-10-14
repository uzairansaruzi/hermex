import OSLog

/// Signpost intervals on the paths users feel most, for Instruments' `os_signpost`
/// instrument: filter by the app's subsystem and category `Performance`
/// (`DEVELOPMENT.md` § Launch arguments and profiling). The intervals are
/// `Launch`, `Session Open`, `Load Earlier`, `Transcript Apply`, `Markdown Parse`,
/// `Stream Batch Apply`, `Cache Read`, and `Cache Write`.
///
/// Compiled into every build, because Instruments profiles Release builds and an
/// idle signposter costs almost nothing until a recording turns it on.
///
/// Privacy: names are static strings and metadata is integers only (counts),
/// marked `.public`. Never put prompt or message text, titles, paths, URLs,
/// session IDs, or model names into a name or its metadata; a trace leaves the
/// device with whoever records it.
let performanceSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "Performance"
)

/// The one `Launch` interval: from the app's `init` to the first frame after a home list
/// (webui's or a Hermes server's) holds session rows, cached or read. Rows in a collapsed group,
/// such as webui's scheduled sessions, count. Pre-main work
/// (dyld, static initializers) is outside it. A launch that never shows rows (onboarding,
/// an empty list) leaves it open; it is never emitted twice.
@MainActor
enum LaunchSignpost {
    private static var state: OSSignpostIntervalState?
    private static var ended = false

    static func begin() {
        state = performanceSignposter.beginInterval("Launch", id: performanceSignposter.makeSignpostID())
    }

    /// Ends the interval on the next main-queue turn, so it includes the rows' layout.
    static func end(rows: Int) {
        guard !ended, rows > 0, let state else { return }
        ended = true
        DispatchQueue.main.async {
            performanceSignposter.endInterval("Launch", state, "rows=\(rows, privacy: .public)")
        }
    }
}

/// The one open `Session Open` interval: from a session-list open
/// (`SessionListView.startOpeningSession`, so taps and keyboard opens alike, or a Hermes
/// list pushing its chat, which also covers its links and shares) to the first transcript
/// frame in `ChatView`. Webui deep links, App Intents, and notification taps are not measured.
///
/// The session ID (a Hermes chat's `HermesSessionChat.id`) only matches an end to its begin
/// and is never emitted.
@MainActor
enum SessionOpenSignpost {
    private static var pending: (sessionID: String, state: OSSignpostIntervalState)?

    /// Starts timing an open. An earlier open that has not finished ends here
    /// first, so no interval is left dangling.
    static func begin(sessionID: String?) {
        if let pending {
            performanceSignposter.endInterval("Session Open", pending.state)
            self.pending = nil
        }
        guard let sessionID else { return }
        let state = performanceSignposter.beginInterval("Session Open", id: performanceSignposter.makeSignpostID())
        pending = (sessionID, state)
    }

    /// Ends the open of `sessionID` with its transcript size, or with no metadata
    /// when `messages` is nil because the open failed before a chat showed. Does
    /// nothing for any other session, or once that open has ended.
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
