import SwiftUI
import HermexCore

public struct HermexWorkspaceScreen: View {
    private let state: HermexWorkspaceState
    private let onEvent: (HermexUIEvent) -> Void

    public init(state: HermexWorkspaceState, onEvent: @escaping (HermexUIEvent) -> Void = { _ in }) {
        self.state = state
        self.onEvent = onEvent
    }

    public var body: some View {
        ZStack {
            HermexUIColors.systemBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topBar

                    if !state.roots.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Roots")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(state.roots) { root in
                                        Button {
                                            onEvent(.openWorkspaceEntry(HermexWorkspaceEntryDTO(
                                                name: root.name ?? root.path,
                                                path: root.path,
                                                type: "dir",
                                                isDirectory: true
                                            )))
                                        } label: {
                                            HermexPillLabel(root.name ?? root.path, systemImage: "folder")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.currentPath ?? "Files")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        if state.isLoading {
                            ProgressView()
                        }
                        ForEach(state.entries) { entry in
                            Button {
                                onEvent(.openWorkspaceEntry(entry))
                            } label: {
                                workspaceRow(entry)
                            }
                            .buttonStyle(.plain)
                        }
                        if state.entries.isEmpty && !state.isLoading {
                            Text(state.errorMessage ?? "No files to show.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                    }

                    if let preview = state.preview {
                        previewPanel(preview)
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
            HermexScreenTitle("Workspace", subtitle: state.currentPath)
            Spacer()
            HermexCircleIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh", action: { onEvent(.refresh) })
        }
    }

    private func workspaceRow(_ entry: HermexWorkspaceEntryDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                .font(.title3.weight(.semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let size = entry.size {
                Text("\(size) B")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .hermexContentShapeRectangle()
    }

    private func previewPanel(_ preview: HermexFilePreview) -> some View {
        HermexGlassPanel(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(preview.path)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(preview.content ?? preview.mimeType ?? "Binary file")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }
}
