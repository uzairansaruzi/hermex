import Foundation
import WidgetKit
import WatchShared
import HermexWatchRoot

@MainActor
enum WatchWidgetSnapshotPublisher {
    static func publish(_ model: WatchRootModel) {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermexWatchAppGroupIdentifier") as? String,
              let directory = WatchWidgetSnapshotStore.containerURL(appGroup: group)
        else { return }
        do {
            if let snapshot = model.widgetSnapshot() {
                try WatchWidgetSnapshotStore.write(snapshot, directory: directory)
            } else {
                try WatchWidgetSnapshotStore.remove(from: directory)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "HermexWatchWidget")
        } catch {}
    }
}
