import OSLog

/// Signpost intervals on the paths users feel most, for Instruments' `os_signpost`
/// instrument: filter by the app's subsystem and category `Performance`
/// (`DEVELOPMENT.md` § Launch arguments and profiling). The intervals are
/// `Session Open`, `Transcript Apply`, `Markdown Parse`, `Stream Batch Apply`,
/// `Cache Read`, and `Cache Write`.
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

/// The one open `Session Open` interval: from a session-list open
/// (`SessionListView.startOpeningSession`, so taps and keyboard opens alike) to
/// the first transcript frame in `ChatView`. Deep links, App Intents, and
/// notification taps are not measured.
///
/// The session ID only matches an end to its begin and is never emitted.
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
