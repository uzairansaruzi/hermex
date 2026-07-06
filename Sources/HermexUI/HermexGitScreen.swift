import Foundation
import SwiftUI
import HermexCore

public struct HermexGitScreen: View {
    private let state: HermexGitState
    private let onEvent: (HermexUIEvent) -> Void

    public init(state: HermexGitState, onEvent: @escaping (HermexUIEvent) -> Void = { _ in }) {
        self.state = state
        self.onEvent = onEvent
    }

    public var body: some View {
        ZStack {
            HermexUIColors.systemBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topBar
                    repositoryCard
                    actionBar
                    commitBox
                    changesList
                    if let diffText = state.diffText {
                        diffPanel(diffText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HermexCircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Back", action: { onEvent(.openRoute(.chat)) })
            HermexScreenTitle("Git", subtitle: state.branch ?? "Branch unavailable")
            Spacer()
            HermexCircleIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh", action: { onEvent(.refresh) })
        }
    }

    private var repositoryCard: some View {
        HermexGlassPanel(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.isRepository ? "Repository" : "Not a repository")
                    .font(.headline.weight(.semibold))
                HStack {
                    Text(state.branch ?? "No branch")
                    Spacer()
                    Text("+\(state.ahead ?? 0) -\(state.behind ?? 0)")
                        .foregroundStyle(.secondary)
                }
                if let upstream = state.upstream {
                    Text(upstream)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Fetch") { onEvent(.gitCommand(.fetch)) }
            Button("Pull") { onEvent(.gitCommand(.pull)) }
            Button("Push") { onEvent(.gitCommand(.push)) }
        }
        .buttonStyle(.bordered)
        .disabled(state.isMutating)
    }

    private var commitBox: some View {
        HermexGlassPanel(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Commit")
                    .font(.headline.weight(.semibold))
                HStack(spacing: 8) {
                    TextField(
                        "Message",
                        text: Binding(
                            get: { state.commitMessage },
                            set: { onEvent(.updateGitCommitMessage($0)) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Commit") {
                        onEvent(.gitCommand(.commit(message: state.commitMessage)))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.commitMessage.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty || state.isMutating)
                }
            }
            .padding(14)
        }
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes")
                .font(.headline.weight(.semibold))
            ForEach(state.files) { file in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(file.status)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                        Text(file.path)
                            .lineLimit(1)
                        Spacer()
                        if let additions = file.additions, let deletions = file.deletions {
                            Text("+\(additions) -\(deletions)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Diff") {
                            onEvent(.gitCommand(.diff(path: file.path, kind: file.isStaged == true ? "staged" : "unstaged")))
                        }
                        if file.isStaged == true {
                            Button("Unstage") { onEvent(.gitCommand(.unstage(path: file.path))) }
                        } else {
                            Button("Stage") { onEvent(.gitCommand(.stage(path: file.path))) }
                        }
                        Button("Discard") { onEvent(.gitCommand(.discard(path: file.path, deleteUntracked: true))) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(state.isMutating)
                    if state.diffPath == file.path, state.diffText != nil {
                        Text("Diff open")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func diffPanel(_ text: String) -> some View {
        HermexGlassPanel(cornerRadius: 14) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }
}
