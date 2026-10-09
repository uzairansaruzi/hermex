import Foundation
import WidgetKit
import WatchShared

struct HermexWatchEntry: TimelineEntry {
    let date: Date
    let snapshot: RedactedWidgetSnapshot?
}

struct HermexWatchTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HermexWatchEntry {
        HermexWatchEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (HermexWatchEntry) -> Void) {
        completion(HermexWatchEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HermexWatchEntry>) -> Void) {
        let entry = HermexWatchEntry(date: Date(), snapshot: loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func loadSnapshot() -> RedactedWidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermexWatchAppGroupIdentifier") as? String,
              let directory = WatchWidgetSnapshotStore.containerURL(appGroup: group)
        else { return nil }
        return try? WatchWidgetSnapshotStore.read(from: directory)
    }
}
