import SafariServices
import UIKit

/// Opens a web page in the app that claims it (a Universal Link, such as a
/// Gmail thread) when one is installed, and otherwise in
/// `SFSafariViewController`, presented as a sheet over whatever is on screen,
/// including another sheet (#1619). UIKit
/// rather than a SwiftUI `.sheet` inside `transcriptLinks`: a presentation
/// modifier there made every link reader re-run on each owner pass
/// (ChatTranscriptEnvironmentStabilityTests). The controller dismisses itself.
/// Only pass links `InAppBrowserPolicy.opensInApp` accepts: the controller
/// raises for any other scheme.
enum SafariView {
    @MainActor
    static func present(_ url: URL) {
        // The sheet never hands a link to its app, and it has none of Safari's
        // sign-ins. UIKit calls back on the main thread.
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            guard !opened else { return }
            MainActor.assumeIsolated { presentSheet(url) }
        }
    }

    @MainActor
    private static func presentSheet(_ url: URL) {
        guard let presenter = topViewController() else {
            UIApplication.shared.open(url)
            return
        }
        let controller = SFSafariViewController(url: url)
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
    }

    /// The front-most view controller in the app's key window, the one the tap
    /// landed in when several scenes are open.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
