import SafariServices
import SwiftUI

/// A web page in `SFSafariViewController`, for a SwiftUI sheet. The
/// controller's own Done (or Close) button dismisses it behind SwiftUI's back,
/// so `onFinish` is where the presenter clears its sheet item. Only pass links
/// `InAppBrowserPolicy.opensInApp` accepts: the controller raises for any other
/// scheme.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}
