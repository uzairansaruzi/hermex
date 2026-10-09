public enum WatchLaunchState: Equatable, Sendable {
    case setupRequired
    case connecting
    case unavailable
    /// The iPhone is configured for this server but the user is signed out
    /// (the phone's session expired or was cleared). The watch cannot
    /// authenticate, so it tells the user to sign in on iPhone.
    case signedOut
    case ready
}
