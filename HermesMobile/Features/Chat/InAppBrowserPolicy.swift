import Foundation

/// Which links open in the in-app browser (`SafariView`) instead of leaving
/// Hermex: web pages only. Mail, phone, and app links keep going to the system.
/// `SFSafariViewController` raises for any scheme but `http(s)`, so every
/// presentation checks this first.
enum InAppBrowserPolicy {
    static func opensInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host()?.isEmpty == false
    }
}
