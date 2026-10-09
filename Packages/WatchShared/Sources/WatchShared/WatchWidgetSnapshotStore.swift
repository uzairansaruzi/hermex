import Foundation

/// Writes and reads the redacted complication snapshot in a caller-supplied
/// directory (normally the watch app group). No URLs or credentials.
public enum WatchWidgetSnapshotStore {
    public static let fileName = "widget-snapshot.json"

    public static func write(_ snapshot: RedactedWidgetSnapshot, directory: URL) throws {
        let data = try snapshot.canonicalJSONData()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    public static func read(from directory: URL) throws -> RedactedWidgetSnapshot? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try RedactedWidgetSnapshot.decode(Data(contentsOf: url))
    }

    /// Drops a leftover snapshot so complications do not keep showing a
    /// previous ready state (or a screenshot fixture) after setup is required.
    public static func remove(from directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func containerURL(appGroup: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}
