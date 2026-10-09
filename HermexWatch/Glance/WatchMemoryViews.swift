import SwiftUI
import HermexWatchRoot
import WatchShared

// MARK: - Memory

/// "What does the agent remember?" One row per memory file with its entry
/// count; each opens to the entries as separate, formatted rows. Editing
/// memory stays on iPhone.
struct WatchMemoryListView: View {
    @Bindable var model: WatchRootModel
    @State private var document: WatchMemoryDocument?
    @State private var phase: WatchGlancePhase = .loading

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: document?.sections.isEmpty ?? true,
                emptyTitle: "Nothing remembered yet",
                emptySymbol: "brain",
                retry: reload
            )
            if let document, !document.sections.isEmpty {
                Section {
                    ForEach(document.sections, id: \.section) { section in
                        let entries = WatchMemoryProjection.entries(in: section.redactedContent)
                        NavigationLink {
                            WatchMemorySectionView(section: section)
                        } label: {
                            sectionRow(section, entries: entries)
                        }
                    }
                } footer: {
                    Text("Editing memory stays on iPhone.")
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func sectionRow(_ section: WatchMemorySection, entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(WatchMemoryPresentation.title(for: section.section))
                    .font(.headline)
                Spacer(minLength: 4)
                Text("\(entries.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let first = entries.first {
                Text(WatchTextBreaking.breakable(WatchTranscriptProjection.plainText(first)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WatchMemoryPresentation.title(for: section.section)), \(entries.count) \(entries.count == 1 ? "entry" : "entries")")
        .accessibilityHint("Opens the entries.")
    }

    private func reload() async {
        if document == nil { phase = .loading }
        let loaded = await model.loadMemory()
        document = loaded ?? document
        phase = loaded == nil ? .after(model) : .loaded
    }
}

enum WatchMemoryPresentation {
    static func title(for section: String) -> String {
        switch section.lowercased() {
        case "memory": return "Agent notes"
        case "user": return "About you"
        case "soul": return "Persona"
        default: return section.capitalized
        }
    }
}

/// One memory file as separate entries, each styled (bold labels, bullets)
/// instead of raw Markdown and `§` separators.
struct WatchMemorySectionView: View {
    let section: WatchMemorySection

    var body: some View {
        let entries = WatchMemoryProjection.entries(in: section.redactedContent)
        List {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                WatchMarkdownText(text: entry)
                    .padding(.vertical, 2)
            }
            if section.isTruncated {
                Text("Shortened for the wrist. Full memory on iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(WatchMemoryPresentation.title(for: section.section))
        .navigationBarTitleDisplayMode(.inline)
    }
}
