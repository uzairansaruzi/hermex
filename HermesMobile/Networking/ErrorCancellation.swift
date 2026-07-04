import Foundation

extension Error {
    /// True when this error only reports that in-flight work was cancelled — a Swift
    /// `CancellationError`, a `URLError` with code `.cancelled`, or an `APIError.network`
    /// wrapping one. View models check this in their catch paths so a request cancelled
    /// mid-flight (for example by quickly popping and re-pushing a screen, which cancels
    /// its `.task`) never surfaces as a user-facing error banner.
    var isCancellation: Bool {
        if self is CancellationError {
            return true
        }

        let underlying: Error
        if let apiError = self as? APIError, case .network(let wrapped) = apiError {
            underlying = wrapped
        } else {
            underlying = self
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }
}
