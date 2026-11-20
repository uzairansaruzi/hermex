import SafariServices
import UIKit

enum SafariView {
    @MainActor
    static func present(_ url: URL) {
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
