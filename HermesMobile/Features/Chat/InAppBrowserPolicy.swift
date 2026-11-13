import Foundation

/// Which links go to `SafariView` (the app that claims the page, else the
/// in-app browser) instead of the system: web pages only. Mail, phone, and app links keep going to the system.
/// `SFSafariViewController` raises for any scheme but `http(s)`, so every
/// presentation checks this first.
enum InAppBrowserPolicy {
    static func opensInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host()?.isEmpty == false
    }
}
