import SwiftUI
import HermexWatchRoot
import WatchShared

// Read-mostly glances behind Now. Each one answers a single wrist question
// ("is anything running?", "what did I spend?") in a scrolling List, keeps its
// own loading / empty / error state, and leaves editing to the iPhone.

/// Load state for one glance. Owned by the screen, so a failure on one glance
/// never shows up as a banner on another.
enum WatchGlancePhase: Equatable {
    case loading
    case loaded
    case failed(String)

    /// Only a code this screen's own load can set. A leftover send, stop or
    /// write failure must not make a list claim it failed to load.
    @MainActor
    static func after(_ model: WatchRootModel) -> WatchGlancePhase {
        switch model.lastErrorCode {
        case "glanceUnavailable", "sessionsUnavailable", "authRequired":
            return .failed(model.errorCopy ?? "Couldn’t load this list.")
        default:
            return .loaded
        }
    }
}

/// One failed wrist action, shown next to the control that failed. Cleared by
/// the next attempt, so a stale failure never outlives the retry.
struct WatchActionErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .accessibilityLabel("Action failed. \(message)")
    }
}

/// Loading spinner, empty state, or error with Try again, as List rows.
struct WatchGlanceStatusRows: View {
    let phase: WatchGlancePhase
    let isEmpty: Bool
    let emptyTitle: String
    let emptySymbol: String
    let retry: () async -> Void

    var body: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
                .listRowBackground(Color.clear)
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Button("Try again") {
                    Task { await retry() }
                }
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        case .loaded where isEmpty:
            VStack(spacing: 6) {
                Image(systemName: emptySymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(emptyTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        case .loaded:
            EmptyView()
        }
    }
}

/// Same Lucide marks as the iPhone sidebar, drawn as templates.
struct WatchNavRow: View {
    let title: String
    var assetImage: String? = nil
    var systemImage: String? = nil
    var detail: String?
    var detailTint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(detailTint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if let assetImage {
            Image(assetImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
}

/// Small capsule for a row's state ("Running", "Off").
struct WatchStatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
    }
}

/// Static relative time ("in 5 hr", "2 days ago"). Computed at render, never
/// ticked: a self-updating label repaints its row every second for a figure
/// nobody watches, and pull to refresh brings it current.
struct WatchRelativeDate: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .monospacedDigit()
    }
}

/// One labelled fact in a detail screen ("Next run", "in 5 hr").
struct WatchFactRow<Value: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            value()
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active Profile

struct WatchProfileListView: View {
    @Bindable var model: WatchRootModel
    @State private var options: WatchComposerOptions?
    @State private var phase: WatchGlancePhase = .loading
    @State private var switchingName: String?
    @State private var switchFailed = false

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: options?.profiles.isEmpty ?? true,
                emptyTitle: "No profiles on this server",
                emptySymbol: "person.crop.circle",
                retry: reload
            )
            if switchFailed {
                WatchActionErrorRow(message: "Couldn’t switch profile.")
            }
            if let options, !options.profiles.isEmpty {
                Section {
                    ForEach(options.profiles, id: \.id) { profile in
                        let selected = profile.id == options.defaultProfileID
                        Button {
                            guard !selected else { return }
                            Task { await switchProfile(profile) }
                        } label: {
                            profileRow(profile, selected: selected)
                        }
                        .disabled(switchingName != nil || !model.canMutate)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint(selected ? "Already the active profile." : "Makes this the active profile.")
                    }
                } footer: {
                    Text("New sessions use the active profile.")
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func profileRow(_ profile: WatchComposerOptions.ProfileChoice, selected: Bool) -> some View {
        let parts = profile.label.split(separator: "\n", maxSplits: 1).map(String.init)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.first ?? profile.label)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                if parts.count > 1 {
                    Text(parts[1])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if switchingName == profile.id.rawValue {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                // A hollow mark on every other row makes the list read as a
                // picker rather than a static list of names.
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func reload() async {
        if options == nil { phase = .loading }
        let loaded = await model.loadComposerOptions()
        options = loaded ?? options
        phase = loaded == nil ? .after(model) : .loaded
    }

    private func switchProfile(_ profile: WatchComposerOptions.ProfileChoice) async {
        switchingName = profile.id.rawValue
        switchFailed = false
        defer { switchingName = nil }
        if await model.switchActiveProfile(name: profile.id.rawValue) {
            WatchHaptics.play(.success)
            await reload()
        } else {
            switchFailed = true
            WatchHaptics.play(.failure)
        }
    }
}

// MARK: - Projects

struct WatchProjectListView: View {
    @Bindable var model: WatchRootModel
    @State private var options: WatchComposerOptions?
    @State private var phase: WatchGlancePhase = .loading

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: options?.workspaces.isEmpty ?? true,
                emptyTitle: "No projects yet",
                emptySymbol: "folder",
                retry: reload
            )
            if let options, !options.workspaces.isEmpty {
                Section {
                    ForEach(options.workspaces, id: \.handle) { project in
                        HStack(spacing: 8) {
                            Image("LucideFolder")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(project.label)
                                .lineLimit(2)
                        }
                    }
                } footer: {
                    Text("Browsing and editing files stays on iPhone.")
                }
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        if options == nil { phase = .loading }
        let loaded = await model.loadComposerOptions()
        options = loaded ?? options
        phase = loaded == nil ? .after(model) : .loaded
    }
}

