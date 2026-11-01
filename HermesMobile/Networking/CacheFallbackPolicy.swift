import Foundation

enum CacheFallbackPolicy {
    static func shouldUseCache(for error: Error) -> Bool {
        switch error {
        case APIError.network(let underlying):
            return isConnectivityError(underlying)
        case APIError.http(let statusCode, _):
            return isTransientUnavailableStatus(statusCode)
        // A Hermes host (#1054): its socket lost or never opened, or a proxy or tunnel answering
        // for a host that isn't there (`BotFailure`'s 502-504 and 520-530 copy). Its sign-in's
        // connectivity errors are raw `URLError`s, as below.
        case BotFailure.transport:
            return true
        case BotFailure.rejected(let code):
            return code == 408 || (502...504).contains(code) || (520...530).contains(code)
        default:
            return isConnectivityError(error)
        }
    }

    private static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .cannotFindHost,
             .dataNotAllowed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    private static func isTransientUnavailableStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 502, 503, 504:
            return true
        default:
            return false
        }
    }
}
