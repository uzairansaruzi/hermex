import SwiftUI
import HermexWatchRoot
import WatchShared

// MARK: - Skills

/// "Which skills can the agent use?" On first, then off. Swipe turns a skill on
/// or off in one gesture; tapping opens the full description with the same
/// switch. Editing a skill stays on iPhone.
struct WatchSkillListView: View {
    @Bindable var model: WatchRootModel
    @State private var skills: [WatchSkillSummary] = []
    @State private var phase: WatchGlancePhase = .loading
    @State private var toggling: String?
    @State private var actionError: String?

    var body: some View {
        List {
            WatchGlanceStatusRows(
                phase: phase,
                isEmpty: skills.isEmpty,
                emptyTitle: "No skills installed",
                emptySymbol: "hammer",
                retry: reload
            )
            if let actionError {
                WatchActionErrorRow(message: actionError)
            }
            ForEach(sortedSkills, id: \.key) { skill in
                NavigationLink {
                    WatchSkillDetailView(model: model, skill: skill) {
                        await reload()
                    }
                } label: {
                    skillRow(skill)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        Task { await toggle(skill) }
                    } label: {
                        Label(
                            skill.enabled == false ? "Turn on" : "Turn off",
                            systemImage: skill.enabled == false ? "power" : "power.circle"
                        )
                    }
                    .tint(skill.enabled == false ? .green : .gray)
                    .disabled(!model.canMutate || skill.enabled == nil)
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func skillRow(_ skill: WatchSkillSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.key.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if toggling == skill.key.name {
                    ProgressView()
                        .frame(width: 20, height: 20)
                } else if skill.enabled == false {
                    WatchStatusBadge(text: "Off", tint: .gray)
                } else if skill.enabled == true {
                    WatchStatusBadge(text: "On", tint: .green)
                }
            }
            if !skill.summary.isEmpty {
                Text(WatchTranscriptProjection.plainText(skill.summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .opacity(skill.enabled == false ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the description. Swipe to turn it on or off.")
    }

    private func toggle(_ skill: WatchSkillSummary) async {
        toggling = skill.key.name
        actionError = nil
        defer { toggling = nil }
        if await model.setSkillEnabled(name: skill.key.name, enabled: skill.enabled == false, scope: skill.key.scope) {
            WatchHaptics.play(.success)
            await reload()
        } else {
            actionError = "Couldn’t update that skill."
            WatchHaptics.play(.failure)
        }
    }

    private var sortedSkills: [WatchSkillSummary] {
        skills.sorted { lhs, rhs in
            let lhsOff = lhs.enabled == false
            let rhsOff = rhs.enabled == false
            if lhsOff != rhsOff { return !lhsOff }
            return lhs.key.name.localizedCaseInsensitiveCompare(rhs.key.name) == .orderedAscending
        }
    }

    private func reload() async {
        if skills.isEmpty { phase = .loading }
        let loaded = await model.loadSkills()
        phase = .after(model)
        if phase == .loaded { skills = loaded }
    }
}

// MARK: - Skill detail

struct WatchSkillDetailView: View {
    @Bindable var model: WatchRootModel
    let onChange: () async -> Void
    @State private var skill: WatchSkillSummary
    @State private var isToggling = false
    @State private var actionError: String?

    init(model: WatchRootModel, skill: WatchSkillSummary, onChange: @escaping () async -> Void) {
        self.model = model
        self.onChange = onChange
        _skill = State(initialValue: skill)
    }

    var body: some View {
        List {
            Section {
                Text(skill.key.name)
                    .font(.headline)
                    .listRowBackground(Color.clear)
                if let enabled = skill.enabled {
                    // The native watch idiom for an on/off setting.
                    Toggle(isOn: Binding(
                        get: { enabled },
                        set: { newValue in Task { await setEnabled(newValue) } }
                    )) {
                        HStack(spacing: 6) {
                            Text(enabled ? "On" : "Off")
                            if isToggling {
                                ProgressView()
                                    .frame(width: 18, height: 18)
                            }
                        }
                    }
                    .disabled(isToggling || !model.canMutate)
                    .accessibilityHint(enabled ? "Turns this skill off for new runs." : "Lets the agent use this skill.")
                }
                if let actionError {
                    WatchActionErrorRow(message: actionError)
                }
            }
            if !skill.summary.isEmpty {
                Section {
                    WatchMarkdownText(text: skill.summary)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Editing skills stays on iPhone.")
                }
            }
        }
        .navigationTitle("Skill")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setEnabled(_ enabled: Bool) async {
        isToggling = true
        actionError = nil
        defer { isToggling = false }
        guard await model.setSkillEnabled(name: skill.key.name, enabled: enabled, scope: skill.key.scope) else {
            actionError = "Couldn’t update that skill."
            WatchHaptics.play(.failure)
            return
        }
        WatchHaptics.play(.success)
        if let updated = try? WatchSkillSummary(key: skill.key, summary: skill.summary, enabled: enabled) {
            skill = updated
        }
        await onChange()
    }
}
