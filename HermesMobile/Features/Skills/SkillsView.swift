import SwiftUI

/// The Skills list: a webui server's, or on a Hermes host (#1069) one Profile's.
struct SkillsView: View {
    let onAPIError: (Error) -> Void
    private let profile: String?

    @State private var viewModel: SkillsViewModel
    @State private var searchText = ""
    /// A failed toggle's notice (#1410).
    @State private var toast = ActionToastState()

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.init(client: APIClient(baseURL: server), onAPIError: onAPIError)
    }

    /// The skills `client` reads. On a Hermes host that is `profile`'s, which the title names.
    init(client: any SkillsDataClient, profile: String? = nil, onAPIError: @escaping (Error) -> Void) {
        self.onAPIError = onAPIError
        self.profile = profile
        _viewModel = State(initialValue: SkillsViewModel(client: client))
    }

    var body: some View {
        content
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .modifier(SkillsTitle(profile: profile))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadSkills() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .task {
                await loadSkills()
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search skills...")
            .overlay(alignment: .bottom) {
                ActionToastView(state: toast)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
            }
            .onChange(of: viewModel.toggleErrorMessage) { _, message in
                guard let message else { return }
                toast.show(.failure(message))
                viewModel.clearToggleError()
            }
            .onDisappear { toast.dismiss() }
    }

    private var filteredGroups: [(category: String, skills: [SkillSummary])] {
        viewModel.filteredGroupedSkills(searchText: searchText)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.skills.isEmpty {
            ProgressView("Loading skills...")
        } else if let errorMessage = viewModel.errorMessage, viewModel.skills.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Skills", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadSkills() }
                }
            }
        } else if viewModel.skills.isEmpty {
            ContentUnavailableView {
                Label("No Skills", systemImage: "hammer")
            } description: {
                Text("Skills from the Hermes server will appear here.")
            }
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredGroups.isEmpty {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text("No skills match \"\(searchText)\".")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(filteredGroups, id: \.category) { group in
                        SkillCategorySection(
                            category: group.category,
                            skills: group.skills,
                            client: viewModel.client,
                            togglingSkillNames: viewModel.togglingSkillNames,
                            onToggleSkill: { skill, enabled in
                                await toggle(skill: skill, enabled: enabled)
                            },
                            onAPIError: onAPIError
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable {
                await loadSkills()
            }
            .background(Color(.appCanvas))
        }
    }

    private func loadSkills() async {
        await viewModel.load()
        if let error = viewModel.lastError {
            onAPIError(error)
        }
    }

    private func toggle(skill: SkillSummary, enabled: Bool) async {
        await viewModel.setSkill(skill, enabled: enabled)
        if let error = viewModel.lastError {
            onAPIError(error)
        }
    }
}

private struct SkillCategorySection: View {
    let category: String
    let skills: [SkillSummary]
    let client: any SkillsDataClient
    let togglingSkillNames: Set<String>
    let onToggleSkill: (SkillSummary, Bool) async -> Void
    let onAPIError: (Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category)
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                    NavigationLink {
                        SkillDetailView(
                            skill: skill,
                            client: client,
                            onAPIError: onAPIError
                        )
                    } label: {
                        SkillRow(
                            skill: skill,
                            isToggling: isToggling(skill),
                            onToggle: canToggle(skill) ? { enabled in
                                Task { await onToggleSkill(skill, enabled) }
                            } : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(skill.disabled == true ? 0.55 : 1)
                    .contextMenu {
                        if canToggle(skill) {
                            let isDisabled = skill.disabled == true
                            Button {
                                Task { await onToggleSkill(skill, isDisabled) }
                            } label: {
                                Label(isDisabled ? "Enable" : "Disable", systemImage: isDisabled ? "checkmark.circle" : "pause.circle")
                            }
                            .disabled(isToggling(skill))
                        }
                    }
                }
            }
        }
    }

    private func canToggle(_ skill: SkillSummary) -> Bool {
        guard skill.disabled != nil else { return false }
        let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(name ?? "").isEmpty
    }

    private func isToggling(_ skill: SkillSummary) -> Bool {
        guard let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return togglingSkillNames.contains(name)
    }
}

private struct SkillRow: View {
    let skill: SkillSummary
    var isToggling: Bool = false
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(2)

                if let description {
                    Text(description)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(3)
                }

                if skill.disabled == true || !tags.isEmpty {
                    HStack(spacing: 6) {
                        if skill.disabled == true {
                            Text("Disabled")
                                .font(AppFont.caption2(weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .foregroundStyle(.appSecondary)
                                .background(Color(.appFillTertiary), in: Capsule())
                        }

                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(AppFont.caption2(weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .foregroundStyle(.appSecondary)
                                .background(Color(.appFillSecondary).opacity(0.8), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if let onToggle {
                Toggle(skill.disabled == true ? "Enable" : "Disable", isOn: Binding(
                    get: { skill.disabled != true },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.8, anchor: .trailing)
                .disabled(isToggling)
                .padding(.top, 6)
            }

            Image(systemName: "chevron.forward")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appTertiary)
                .padding(.top, 12)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onToggle {
                Button(skill.disabled == true ? "Enable" : "Disable") {
                    guard !isToggling else { return }
                    onToggle(skill.disabled == true)
                }
            }
        }
    }

    private var displayName: String {
        let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Unnamed Skill")
        }
        return name
    }

    private var description: String? {
        let text = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private var tags: [String] {
        (skill.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// One skill's SKILL.md, and its linked files where the server lists them (`skillsFeatures`).
struct SkillDetailView: View {
    let skill: SkillSummary
    let client: any SkillsDataClient
    let onAPIError: (Error) -> Void

    @State private var detail: SkillDetailResponse?
    /// True from the start, so the page shows progress, not "No Content", until its load runs.
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedFile: String?
    @State private var openedFile: SkillDetailResponse?
    @State private var isLoadingFile = false

    var body: some View {
        content
            .themedPageBackground()
            .navigationTitle(skill.name ?? String(localized: "Skill"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadDetail() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadDetail()
            }
            .sheet(item: $selectedFile) { fileName in
                NavigationStack {
                    SkillLinkedFileView(
                        fileName: fileName,
                        content: openedFile?.content,
                        isLoading: isLoadingFile,
                        isBinary: openedFile?.isBinary == true,
                        isTruncated: openedFile?.isTruncated == true
                    )
                }
                .adaptivePagePresentation()
            }
            .transcriptLinks()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && detail == nil {
            ProgressView("Loading skill...")
        } else if let errorMessage, detail == nil {
            ContentUnavailableView {
                Label("Could Not Load Skill", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadDetail() }
                }
            }
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let content = detail.content, !content.isEmpty {
                        MarkdownRenderer(content: content)
                            .padding(.horizontal)
                    }

                    if client.skillsFeatures.hasLinkedFiles, let linkedFiles = detail.linkedFiles, !linkedFiles.isEmpty {
                        SkillLinkedFilesSection(
                            fileNames: linkedFiles,
                            onSelect: { fileName in
                                Task { await loadLinkedFile(named: fileName) }
                            }
                        )
                    }
                }
                .padding(.vertical)
            }
        } else {
            ContentUnavailableView {
                Label("No Content", systemImage: "doc.text")
            } description: {
                Text("This skill has no content.")
            }
        }
    }

    private func loadDetail() async {
        guard let name = skill.name else { isLoading = false; return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await client.skillContent(name: name, file: nil)
            detail = response
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }

    private func loadLinkedFile(named fileName: String) async {
        guard let name = skill.name else { return }
        isLoadingFile = true
        selectedFile = fileName
        openedFile = nil

        let loaded: SkillDetailResponse
        do {
            loaded = try await client.skillContent(name: name, file: fileName)
        } catch {
            loaded = SkillDetailResponse(name: name, content: String(localized: "Could not load file: \(error.localizedDescription)"),
                                         linkedFiles: nil)
        }
        // A slow read for a file the sheet has left must not land under another file's title.
        guard selectedFile == fileName else { return }
        openedFile = loaded
        isLoadingFile = false
    }
}

/// Titles the Skills list. On a Hermes host it also names the Profile the list is for: under
/// the title on iOS 26, and in the title before that.
private struct SkillsTitle: ViewModifier {
    let profile: String?

    func body(content: Content) -> some View {
        if let profile {
            if #available(iOS 26, *) {
                content.themedPageBackground().navigationTitle("Skills").navigationSubtitle(profile)
            } else {
                content.themedPageBackground().navigationTitle(Text("Skills · \(profile)"))
            }
        } else {
            content.themedPageBackground().navigationTitle("Skills")
        }
    }
}

private struct SkillLinkedFilesSection: View {
    let fileNames: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked Files")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(fileNames, id: \.self) { fileName in
                    Button {
                        onSelect(fileName)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(AppFont.subheadline(weight: .medium))
                                .foregroundStyle(.appPrimary)
                                .frame(width: 34, height: 34)
                                .background(Color(.appFillTertiary).opacity(0.7), in: Circle())

                            Text(fileName)
                                .font(AppFont.subheadline())
                                .foregroundStyle(.appPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.forward")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(.appTertiary)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// One linked file's text. A Hermes host (#1070) also says when the file is not text, which has
/// no preview, and when the text is only the start of the file.
struct SkillLinkedFileView: View {
    let fileName: String
    let content: String?
    let isLoading: Bool
    var isBinary = false
    var isTruncated = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading file...")
            } else if isBinary {
                ContentUnavailableView {
                    Label("No Preview", systemImage: "doc.questionmark")
                } description: {
                    Text("Preview is not available for this file type.")
                }
            } else if let content, !content.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if isTruncated {
                            Label("Preview truncated", systemImage: "scissors")
                                .font(AppFont.caption())
                                .foregroundStyle(.appSecondary)
                        }
                        MarkdownRenderer(content: content)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("No Content", systemImage: "doc.text")
                } description: {
                    Text("This file appears to be empty.")
                }
            }
        }
        .themedPageBackground()
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .transcriptLinks()
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
