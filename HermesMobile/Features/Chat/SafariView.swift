import SafariServices
import UIKit

/// Opens a web page in `SFSafariViewController`, presented as a sheet over
/// whatever is on screen, including another sheet. UIKit
/// rather than a SwiftUI `.sheet` inside `transcriptLinks`: a presentation
/// modifier there made every link reader re-run on each owner pass
/// (ChatTranscriptEnvironmentStabilityTests). The controller dismisses itself.
/// Only pass links `InAppBrowserPolicy.opensInApp` accepts: the controller
/// raises for any other scheme.
enum SafariView {
    @MainActor
    static func present(_ url: URL) {
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
