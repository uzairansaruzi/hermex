import UserNotifications

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

    override func serviceExtensionTimeWillExpire() {
        if let delivered = lock.withLock({ delivered }) { deliver(delivered) }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}
