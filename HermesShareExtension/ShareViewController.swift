import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private var didStartOpening = false
    private var alertAwaitingAppearance: UIAlertController?
    private var didAppear = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard !didStartOpening else { return }
        didStartOpening = true

        Task {
            await saveDraftAndOpenHermes()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        if let alertAwaitingAppearance {
            self.alertAwaitingAppearance = nil
            present(alertAwaitingAppearance, animated: true)
        }
    }

    private func configureView() {
        view.backgroundColor = .clear
        view.isOpaque = false

        statusLabel.text = "Opening Hermex..."
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func saveDraftAndOpenHermes() async {
        let input = await ShareInputReader.input(from: extensionContext)
        let draft = HermesShareDraft.draftText(textSnippets: input.textSnippets, urls: input.urls)

        guard !draft.isEmpty || !input.attachments.isEmpty else {
            showNothingAdded(skipped: input.skipped)
            return
        }

        guard let directory = HermesShareDraft.containerURL() else {
            showStatus("Could not access Hermex storage.")
            completeRequest(after: 0.8)
            return
        }

        do {
            try HermesShareDraft.savePendingImport(
                draft: draft,
                attachments: input.attachments,
                skipped: input.skipped,
                in: directory
            )
        } catch {
            showStatus("Could not save shared content.")
            completeRequest(after: 0.8)
            return
        }

        openHermes()
    }

    private func showNothingAdded(skipped: [SharedSkippedItem]) {
        let message = [Self.reason(for: skipped), "Hermex accepts text, URLs, images, PDFs, and files up to 20 MB."]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let alert = UIAlertController(title: "Nothing was added", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        if didAppear {
            present(alert, animated: true)
        } else {
            alertAwaitingAppearance = alert
        }
    }

    private static func reason(for skipped: [SharedSkippedItem]) -> String? {
        guard let first = skipped.first else { return nil }
        let name = first.filename ?? "The item"
        let reason = switch first.reason {
        case .tooLarge: "\(name) is over 20 MB."
        case .unsupported: "Hermex can’t attach \(name)."
        case .unreadable, .overLimit, nil: "\(name) couldn’t be read."
        }
        let rest = skipped.count - 1
        guard rest > 0 else { return reason }
        return "\(reason) \(rest == 1 ? "1 more item" : "\(rest) more items") couldn’t be added."
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    private func openHermes() {
        let url = HermesShareDraft.openURL

        extensionContext?.open(url, completionHandler: { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    self.openHermesViaWorkaround(url)
                }
            }
        })
    }

    private func openHermesViaWorkaround(_ url: URL) {
        let application = containingApplicationResponder()
        if let application, open(url, using: application) {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        if openViaResponderChain(url) || openViaContainingApplication(url) {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        showStatus("Shared content saved. Open Hermex manually.")
        completeRequest(after: 1.5)
    }

    private func openViaContainingApplication(_ url: URL) -> Bool {
        let sharedApplicationSelector = NSSelectorFromString("sharedApplication")
        let openURLModernSelector = NSSelectorFromString("openURL:options:completionHandler:")

        guard
            let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
            applicationClass.responds(to: sharedApplicationSelector),
            let application = applicationClass.perform(sharedApplicationSelector)?.takeUnretainedValue() as? NSObject
        else {
            return false
        }

        if application.responds(to: openURLModernSelector),
           let implementation = application.method(for: openURLModernSelector) {
            typealias OpenURLModernFunction = @convention(c) (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
            let openURL = unsafeBitCast(implementation, to: OpenURLModernFunction.self)
            openURL(application, openURLModernSelector, url as NSURL, [:] as NSDictionary, nil)
            return true
        }

        return false
    }

    private func containingApplicationResponder() -> UIResponder? {
        guard let applicationClass = NSClassFromString("UIApplication") else {
            return nil
        }

        var responder: UIResponder? = self
        while let currentResponder = responder {
            if currentResponder.isKind(of: applicationClass) {
                return currentResponder
            }

            responder = currentResponder.next
        }

        return nil
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self

        while let currentResponder = responder {
            if open(url, using: currentResponder) {
                return true
            }

            responder = currentResponder.next
        }

        return false
    }

    private func open(_ url: URL, using responder: UIResponder) -> Bool {
        if let application = responder as? UIApplication {
            application.open(url, options: [:], completionHandler: nil)
            return true
        }

        let openURLModernSelector = NSSelectorFromString("openURL:options:completionHandler:")
        if responder.responds(to: openURLModernSelector),
           let implementation = responder.method(for: openURLModernSelector) {
            typealias OpenURLModernFunction = @convention(c) (UIResponder, Selector, NSURL, NSDictionary, Any?) -> Void
            let openURL = unsafeBitCast(implementation, to: OpenURLModernFunction.self)
            openURL(responder, openURLModernSelector, url as NSURL, [:] as NSDictionary, nil)
            return true
        }

        return false
    }

    private func completeRequest(after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
