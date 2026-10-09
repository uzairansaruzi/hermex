import Foundation

public enum WatchCompanionError: Error, Equatable, Sendable {
    case unsupported(WatchOperationKind)
    case scopeRejected
    case phoneUnavailable
    case backend(SanitizedDiagnosticCode)
}
