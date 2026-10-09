import SwiftUI
import HermexWatchRoot
import WatchShared

@main
struct HermexWatchApp: App {
    @State private var model = WatchRootModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model, screenshotPage: Self.screenshotPage)
                .onAppear {
                    #if DEBUG
                    if Self.usesScreenshotFixture {
                        model.applyScreenshotFixture(
                            replyError: Self.screenshotPage == .nowReplyError ? "sendFailed" : nil
                        )
                        WatchWidgetSnapshotPublisher.publish(model)
                        return
                    }
                    #endif
                    wireReachability()
                    wireReplyNotice()
                    WatchSessionActivator.shared.activate()
                    model.attach(link: WatchConnectivitySessionLink())
                    WatchWidgetSnapshotPublisher.publish(model)
                    Task { await WatchReplyNotifier.prepare() }
                }
                .onOpenURL { url in
                    guard WatchComplicationLink.isRecord(url) else { return }
                    model.armComplicationRecording()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setWatchForeground(phase == .active)
                    // Returning to the foreground reloads the registry so an
                    // iPhone active-server switch while the watch was
                    // backgrounded is followed, and a quiet phone is surfaced
                    // honestly instead of showing a stale ready surface.
                    guard phase == .active else { return }
                    #if DEBUG
                    if Self.usesScreenshotFixture { return }
                    #endif
                    model.refreshConnection()
                    WatchWidgetSnapshotPublisher.publish(model)
                }
        }
    }

    /// Wires WCSession activation/reachability callbacks to the model so a
    /// reconnect (after backgrounding, or a quiet phone waking up) refreshes
    /// the wrist. The watch never talks to hermes-webui here — it only asks the
    /// model to re-attach its WatchConnectivity link.
    /// A finished watch-started reply. If the wrist isn't looking at Now,
    /// it becomes its own notification. The full turn is still on the card.
    private func wireReplyNotice() {
        WatchSessionActivator.shared.replyArrived = { body in
            Task { @MainActor in
                await model.refreshFromList()
                guard !model.isWatchForeground else { return }
                await WatchReplyNotifier.post(body)
            }
        }
    }

    private func wireReachability() {
        WatchSessionActivator.shared.reachabilityChanged = { reachable in
            Task { @MainActor in
                if reachable {
                    model.handleCompanionReachable()
                } else {
                    model.handleCompanionUnreachable()
                }
                WatchWidgetSnapshotPublisher.publish(model)
            }
        }
    }

    #if DEBUG
    private static var usesScreenshotFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("HERMEX_WATCH_SCREENSHOT_FIXTURE")
    }
    #endif

    private static var screenshotPage: WatchScreenshotPage {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("HERMEX_WATCH_SCREENSHOT_PAGE=") })?
            .split(separator: "=").last
        {
            return WatchScreenshotPage(rawValue: String(raw)) ?? .now
        }
        #endif
        return .now
    }
}
