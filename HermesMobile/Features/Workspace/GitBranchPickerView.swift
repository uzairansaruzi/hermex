import SwiftUI

struct GitBranchPickerButton: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let currentBranch: String
    let branches: GitBranches?
    let isLoading: Bool
    let isSwitching: Bool
    let isDisabled: Bool
    let onSelect: (GitCheckoutTarget) -> Void
    let onCreate: (GitCheckoutTarget) -> Void
    let onRefresh: () -> Void

    @State private var showsPicker = false

    var body: some View {
        Button {
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            showsPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .regular))
                Text(currentBranch)
                    .font(AppFont.subheadline())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .adaptiveGlass(
                .regular,
                isInteractive: true,
                fallbackMaterial: .ultraThinMaterial,
                in: Capsule()
            )
            .clipShape(Capsule())
            .chatMinimumHitTarget(in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading || isSwitching)
        .accessibilityLabel("Current Git branch")
        .accessibilityValue(currentBranch)
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            GitBranchPickerSheet(
                branches: branches,
                currentBranch: currentBranch,
                isLoading: isLoading,
                isSwitching: isSwitching,
                onSelect: { target in
                    showsPicker = false
                    onSelect(target)
                },
                onCreate: { target in
                    showsPicker = false
                    onCreate(target)
                },
                onRefresh: onRefresh
            )
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 400, minHeight: 260, idealHeight: 360, maxHeight: 480)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct GitBranchPickerSheet: View {
    let branches: GitBranches?
    let currentBranch: String
    let isLoading: Bool
    let isSwitching: Bool
    let onSelect: (GitCheckoutTarget) -> Void
    let onCreate: (GitCheckoutTarget) -> Void
    let onRefresh: () -> Void

    @State private var searchText = ""
    @State private var showsCreatePrompt = false
    @State private var newBranchName = ""

    private var localBranches: [GitBranchRef] {
        filtered(branches?.local ?? [])
    }

    private var remoteBranches: [GitBranchRef] {
        filtered(branches?.remote ?? []).filter { $0.name?.hasSuffix("/HEAD") != true }
    }

    private var canCreate: Bool {
        !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Local") {
                    ForEach(localBranches, id: \.name) { branch in
                        branchButton(branch, mode: .local)
                    }
                }

                if !remoteBranches.isEmpty {
                    Section("Remote") {
                        ForEach(remoteBranches, id: \.name) { branch in
                            branchButton(branch, mode: .remote)
                        }
                    }
                }

                Section {
                    Button {
                        newBranchName = ""
                        showsCreatePrompt = true
                    } label: {
                        Label("New branch...", systemImage: "plus")
                    }
                    .disabled(isSwitching)

                    Button(action: onRefresh) {
                        Label(
                            isSwitching ? "Switching..." : (isLoading ? "Refreshing..." : "Reload branch list"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isLoading || isSwitching)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search branches")
            .overlay {
                if isLoading, branches == nil { ProgressView() }
            }
        }
        .alert("New Branch", isPresented: $showsCreatePrompt) {
            TextField("hermex/my-feature", text: $newBranchName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                // Alert action buttons ignore `.disabled` at runtime, so guard here to
                // avoid sending an empty branch name to the server (which 400s).
                guard !name.isEmpty else { return }
                onCreate(GitCheckoutTarget(ref: currentBranch, mode: .local, newBranch: name))
            }
            .disabled(!canCreate)
        } message: {
            Text("Create the branch from the current HEAD and switch to it.")
        }
    }

    private func filtered(_ values: [GitBranchRef]) -> [GitBranchRef] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter { $0.name?.localizedCaseInsensitiveContains(query) == true }
    }

    private func branchButton(_ branch: GitBranchRef, mode: GitBranchMode) -> some View {
        let name = branch.name ?? ""
        let isCurrent = name == currentBranch
        return Button {
            onSelect(GitCheckoutTarget(ref: name, mode: mode, track: mode == .remote))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "checkmark" : "arrow.triangle.branch")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.primary)
                    if let subject = branch.subject, !subject.isEmpty {
                        Text(subject).font(AppFont.caption()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isCurrent { badge("Current") }

                if (branch.ahead ?? 0) > 0 || (branch.behind ?? 0) > 0 {
                    Text("↑\(branch.ahead ?? 0) ↓\(branch.behind ?? 0)")
                        .font(AppFont.mono(style: .caption2))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isCurrent || name.isEmpty || isSwitching)
    }

    private func badge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(AppFont.mono(style: .caption2))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .appSurfaceBackground(.inset, in: Capsule())
    }
}
