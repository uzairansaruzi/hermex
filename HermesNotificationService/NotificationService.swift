import UserNotifications

/// Runs when a relay banner arrives (`mutable-content`), including while the app is
/// suspended or terminated. It opens the sealed preview with the key the app left in
/// the shared Keychain group and rewrites the banner; all of that lives in
/// `PushPreview.rewrite`. This target links no networking, SwiftData or packages.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var delivered: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            delivered = request.content
        }
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(request.content)
            return
        }
        PushPreview.rewrite(content, candidates: PushPreviewKeys.stored())
        deliver(content)
    }

    /// Out of time: show the notification exactly as the relay delivered it.
    override func serviceExtensionTimeWillExpire() {
        if let delivered = lock.withLock({ delivered }) { deliver(delivered) }
    }

    /// The system calls the expiry hook on its own thread while `didReceive` may still
    /// be working, and the handler must run exactly once: whoever gets here first wins.
    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}
