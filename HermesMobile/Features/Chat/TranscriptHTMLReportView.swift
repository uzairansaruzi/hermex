import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TranscriptHTMLReportView<FileCard: View>: View {
    let reference: TranscriptMediaReference
    let cacheNamespace: String
    let loader: TranscriptHTMLReportLoader
    let onExpand: () -> Void
    @ViewBuilder let fileCard: () -> FileCard

    @Environment(\.responseSelectionScope) private var selectionScope
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model = TranscriptHTMLReportModel()
    @State private var admittedID: String?
    @State private var width: CGFloat = 0
    @State private var measurement: HTMLReportMeasurement?
    @State private var isLive = false
    @State private var isPainted = false
    @State private var handle = HTMLReportWebViewHandle()
    @State private var export: FileExportPayload?
    @State private var exportErrorMessage: String?

    private static var placeholderHeight: CGFloat { 180 }
    private static var fadeHeight: CGFloat { 56 }

    var body: some View {
        if model.phase == .oversized {
            fileCard()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                strip
                page
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            .onChange(of: cacheKey) {
                isPainted = false
                measurement = HTMLReportCache.measurement(for: cacheKey) ?? measurement
            }
            .loadsOnceVisible(id: reference.id) { admittedID = $0 }
            .task(id: LoadKey(admittedID: admittedID, attempt: model.attempt, attach: loader.loadKey)) {
                guard admittedID == reference.id else { return }
                await model.load(reference, using: loader)
            }
            .task(id: isVisible) { await followVisibility() }
            .fileExporter(
                isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                document: export.map { ExportedFileDocument(data: $0.data) },
                contentType: export?.contentType ?? .data,
                defaultFilename: export?.filename
            ) { result in
                if case let .failure(error) = result { exportErrorMessage = error.localizedDescription }
            }
            .alert(
                "Download Failed",
                isPresented: Binding(get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } })
            ) {
                Button("OK") { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(.appTextSecondary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(reference.displayName)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(Color(.appText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = loadedData.map({ ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) }) {
                    Text(size)
                        .font(AppFont.caption2())
                        .foregroundStyle(Color(.appTextSecondary))
                }
            }

            Spacer(minLength: 8)

            Button(action: startExport) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(loadedData == nil)
            .accessibilityLabel(String(localized: "Download \(reference.displayName)"))

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.chatTactile(.icon))
            .accessibilityLabel(String(localized: "Expand \(reference.displayName)"))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.phase {
        case .failed:
            failedPage
        default:
            ZStack(alignment: .top) {
                if !isPainted {
                    if let snapshot = HTMLReportSnapshots.shared.image(for: cacheKey) {
                        Image(uiImage: snapshot)
                            .resizable()
                            .frame(height: pageHeight)
                            .accessibilityHidden(true)
                    } else {
                        placeholder
                    }
                }
                if isLive, let html = model.html {
                    HTMLReportWebView(
                        html: html,
                        theme: theme,
                        scrolls: false,
                        handle: handle,
                        onMeasure: lockHeight,
                        onFailure: model.renderFailed,
                        onAnchorTap: onExpand
                    )
                    .accessibilityLabel(reference.displayName)
                    .id(cacheKey)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: pageHeight, alignment: .top)
            .mask { fadeMask }
            .clipped()
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(.appFill).opacity(0.5))
            .overlay {
                if model.phase == .loading || isLive {
                    ProgressView().tint(Color(.appTextTertiary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var failedPage: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color(.appTextSecondary))
                .accessibilityHidden(true)
            Text("Couldn't display this report.")
                .font(AppFont.footnote())
                .foregroundStyle(Color(.appTextSecondary))
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .font(AppFont.footnote(weight: .semibold))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fadeMask: some View {
        if measurement?.isClipped == true {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, 1 - Self.fadeHeight / pageHeight)),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Rectangle()
        }
    }

    private struct LoadKey: Equatable {
        let admittedID: String?
        let attempt: Int
        let attach: Int?
    }

    private var isVisible: Bool { selectionScope?.collectsGlyphs ?? true }

    private var cacheKey: String {
        HTMLReportCache.key(namespace: cacheNamespace, reference: reference, width: width,
                            family: AppFontSettings.shared.family, dynamicTypeSize: dynamicTypeSize)
    }

    private var pageHeight: CGFloat { measurement?.height ?? Self.placeholderHeight }

    private var loadedData: Data? { model.data }

    private var theme: HTMLReportTheme {
        HTMLReportTheme(appearance: appearance, colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
    }

    private func followVisibility() async {
        guard !isVisible else {
            isLive = true
            return
        }
        guard isLive else { return }
        if isPainted, let image = await handle.snapshot() {
            guard !Task.isCancelled else { return }
            HTMLReportSnapshots.shared.store(image, for: cacheKey)
        }
        guard !Task.isCancelled else { return }
        isLive = false
        isPainted = false
    }

    private func lockHeight(_ contentHeight: CGFloat) {
        let contentKey = "\(cacheKey)|\(model.contentTag ?? "")"
        if let locked = HTMLReportCache.measurement(for: contentKey) {
            HTMLReportCache.store(locked, for: cacheKey)
            measurement = locked
        } else {
            let cap = Self.heightCap
            let next = HTMLReportMeasurement(height: min(max(contentHeight, 24), cap), isClipped: contentHeight > cap)
            HTMLReportCache.store(next, for: contentKey)
            HTMLReportCache.store(next, for: cacheKey)
            measurement = next
        }
        isPainted = true
    }

    private static var heightCap: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
            .first ?? 800
        return (screen * 3).rounded()
    }

    private func retry() {
        isPainted = false
        model.retry()
    }

    private func startExport() {
        guard let loadedData else { return }
        export = TranscriptMediaExportSupport.payload(for: reference, data: loadedData, resolvedKind: .data)
    }
}
