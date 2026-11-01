import SwiftUI

/// About's view of `DiagnosticsStore`: About reads the count from it and Diagnostics lists and
/// deletes through it. Disk work runs off the main actor; a load publishes only while it is the
/// latest one and its view is still there.
@MainActor @Observable final class DiagnosticsModel {
    /// Nil until the first load finishes.
    private(set) var entries: [DiagnosticsStore.Entry]?

    @ObservationIgnored private let store: DiagnosticsStore
    @ObservationIgnored private var loadGeneration = 0

    init(store: DiagnosticsStore = .shared) {
        self.store = store
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let store = store
        let entries = await Task.detached { store.entries() }.value
        guard !Task.isCancelled, generation == loadGeneration else { return }
        self.entries = entries
    }

    /// Loads, then reloads each time the store keeps a new report, until the calling task is
    /// cancelled. About and Diagnostics run it from `.task`, so a report MetricKit delivers while
    /// either is on screen shows up without leaving the page.
    func observe() async {
        let saves = NotificationCenter.default.notifications(named: DiagnosticsStore.didSaveNotification, object: store)
        await load()
        for await _ in saves {
            await load()
        }
    }

    func delete(id: String) async {
        let store = store
        await Task.detached { store.delete(id: id) }.value
        await load()
    }

    func deleteAll() async {
        let store = store
        await Task.detached { store.deleteAll() }.value
        await load()
    }
}

/// The kept MetricKit reports, newest first (#1397). A report opens its exact copied JSON; swipe
/// deletes one, Delete All every one.
struct SettingsDiagnosticsPage: View {
    let model: DiagnosticsModel

    @State private var isConfirmingDeleteAll = false

    var body: some View {
        let entries = model.entries ?? []
        List {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                            .swipeActions {
                                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                                    Task { await model.delete(id: entry.id) }
                                }
                            }
                    }
                } footer: {
                    Text("iOS delivers these reports. Hermex keeps up to 10 for 14 days, on this device only.")
                }
            }
        }
        .overlay {
            if model.entries?.isEmpty == true {
                ContentUnavailableView {
                    Label(String(localized: "No Reports"), systemImage: "stethoscope")
                } description: {
                    Text("No reports yet. iOS decides when to deliver crash and hang reports, so a recent problem may not show here yet.")
                }
            }
        }
        .toolbar {
            if !entries.isEmpty {
                Button(String(localized: "Delete All"), role: .destructive) {
                    isConfirmingDeleteAll = true
                }
            }
        }
        .confirmationDialog(
            String(localized: "Delete all diagnostic reports?"),
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete All"), role: .destructive) {
                Task { await model.deleteAll() }
            }
        }
        .settingsPage(String(localized: "Diagnostics"))
        .task { await model.observe() }
    }

    @ViewBuilder
    private func row(_ entry: DiagnosticsStore.Entry) -> some View {
        if let report = entry.report, let text = entry.text {
            NavigationLink {
                DiagnosticReportPage(title: report.kind.title, text: text) {
                    Task { await model.delete(id: entry.id) }
                }
            } label: {
                DiagnosticRowLabel(
                    title: report.kind.title,
                    systemImage: report.kind.systemImage,
                    detail: report.windowDescription
                )
            }
        } else {
            DiagnosticRowLabel(
                title: String(localized: "Report unavailable"),
                systemImage: "exclamationmark.triangle",
                detail: entry.received.formatted(date: .abbreviated, time: .omitted)
            )
        }
    }
}

private struct DiagnosticRowLabel: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

/// One report's stored JSON, selectable, exactly as Copy puts it on the pasteboard.
private struct DiagnosticReportPage: View {
    let title: String
    let text: String
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isCopied = false

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(AppFont.footnote().monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isCopied ? String(localized: "Copied") : String(localized: "Copy")) {
                    UIPasteboard.general.string = text
                    isCopied = true
                    AccessibilityNotification.Announcement(String(localized: "Copied")).post()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
        }
    }
}

private extension DiagnosticReport.Kind {
    var title: String {
        switch self {
        case .crash: String(localized: "Crash")
        case .hang: String(localized: "Hang")
        case .cpu: String(localized: "CPU")
        case .diskWrites: String(localized: "Disk writes")
        }
    }

    var systemImage: String {
        switch self {
        case .crash: "xmark.octagon"
        case .hang: "hourglass"
        case .cpu: "cpu"
        case .diskWrites: "internaldrive"
        }
    }
}

private extension DiagnosticReport {
    /// "Oct 28 – Oct 29 · Build 412": the payload's window, then the build it came from.
    var windowDescription: String {
        // Ordered again: a range built from a file whose dates were swapped would trap.
        let window = (min(windowStart, windowEnd)..<max(windowStart, windowEnd))
            .formatted(.interval.month(.abbreviated).day())
        guard let appBuildVersion else { return window }
        return String(localized: "\(window) · Build \(appBuildVersion)")
    }
}
