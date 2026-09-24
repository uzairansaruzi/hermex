import Foundation
import UniformTypeIdentifiers

@Observable
final class FilePreviewViewModel {
    private let session: SessionSummary
    private let path: String
    private let apiClient: APIClient

    private(set) var preview: FilePreviewContent?
    /// Lazy-render chunks for a large Markdown preview; nil renders the file as one document.
    private(set) var markdownChunks: [MarkdownPreviewChunk]?
    private(set) var isLoading = false
    private(set) var isExporting = false
    private(set) var errorMessage: String?
    private(set) var exportErrorMessage: String?
    private(set) var lastError: Error?
    private var exportData: Data?

    /// A text fetch the file tree started on press-down; consumed by the first `load()`.
    private var prefetchedFile: Task<FileResponse, Error>?

    init(
        session: SessionSummary,
        server: URL,
        path: String,
        apiClient: APIClient? = nil,
        prefetchedFile: Task<FileResponse, Error>? = nil
    ) {
        self.session = session
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.prefetchedFile = prefetchedFile
    }

    /// True for paths the preview renders as Markdown rather than as source.
    static func isMarkdownPath(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(pathExtension(of: path))
    }

    /// True for paths that load through `/api/file` as text rather than as image or raw bytes.
    static func loadsTextPreview(forPath path: String) -> Bool {
        let pathExtension = pathExtension(of: path)
        return !rasterImageExtensions.contains(pathExtension) && !unsupportedBinaryExtensions.contains(pathExtension)
    }

    var canExportFile: Bool {
        session.sessionId?.isEmpty == false && !path.isEmpty
    }

    var canSaveImageToPhotos: Bool {
        canExportFile && isRasterImagePath
    }

    @MainActor
    func load() async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        guard !path.isEmpty else {
            errorMessage = String(localized: "File path is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        exportErrorMessage = nil
        lastError = nil

        do {
            if isRasterImagePath {
                let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
                exportData = data
                if let previewData = ImagePreviewDownsampler.previewData(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    preview = .image(.init(data: previewData, originalByteCount: data.count))
                } else {
                    preview = .unavailable(String(localized: "Could not decode this image."))
                }
            } else if isKnownUnsupportedBinaryPath {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
            } else {
                let prefetched = prefetchedFile
                prefetchedFile = nil
                let file: FileResponse
                if let prefetched, let result = try? await prefetched.value {
                    file = result
                } else {
                    file = try await apiClient.file(sessionID: sessionID, path: path)
                }
                exportData = Data((file.content ?? "").utf8)
                markdownChunks = Self.isMarkdownPath(path)
                    ? MarkdownPreviewChunker.chunks(for: file.content ?? "")
                    : nil
                preview = .text(file)
            }
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func exportPayload() async throws -> FileExportPayload {
        guard let sessionID = session.sessionId else {
            throw FileExportError.missingSessionID
        }

        guard !path.isEmpty else {
            throw FileExportError.missingPath
        }

        if let exportData {
            return payload(with: exportData)
        }

        isExporting = true
        exportErrorMessage = nil
        lastError = nil
        defer {
            isExporting = false
        }

        do {
            let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
            exportData = data
            return payload(with: data)
        } catch {
            lastError = error
            exportErrorMessage = error.localizedDescription
            throw error
        }
    }

    private static let rasterImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp"]

    private static let unsupportedBinaryExtensions: Set<String> = [
        "7z", "a", "aiff", "avi", "bin", "bz2", "class", "db", "dmg", "doc",
        "docx", "dylib", "exe", "flac", "gz", "jar", "m4a", "mov", "mp3",
        "mp4", "o", "pdf", "pkg", "ppt", "pptx", "pyc", "rar", "sqlite",
        "svg", "tar", "tgz", "wav", "xls", "xlsx", "xz", "zip"
    ]

    private static func pathExtension(of path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    private var pathExtension: String {
        Self.pathExtension(of: path)
    }

    private var isRasterImagePath: Bool {
        Self.rasterImageExtensions.contains(pathExtension)
    }

    private var isKnownUnsupportedBinaryPath: Bool {
        Self.unsupportedBinaryExtensions.contains(pathExtension)
    }

    private func payload(with data: Data) -> FileExportPayload {
        FileExportPayload(
            data: data,
            filename: exportFilename,
            contentType: UTType(filenameExtension: pathExtension) ?? .data,
            isImage: isRasterImagePath,
            isVideo: isVideoPath
        )
    }

    private var isVideoPath: Bool {
        ["m4v", "mov", "mp4"].contains(pathExtension)
    }

    private var exportFilename: String {
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? String(localized: "Hermes File") : lastPathComponent
    }
}

/// One slice of a large Markdown preview, laid out lazily. `topSpacing` is the gap
/// the whole document would have drawn above this chunk's first block.
struct MarkdownPreviewChunk: Identifiable, Equatable {
    let id: Int
    let text: String
    let topSpacing: CGFloat
}

/// Splits a large Markdown file once, on load, at the streaming splitter's safe block
/// boundaries (blank lines, headings, closed fences), so the preview lays out and
/// highlights only the chunks near the screen instead of the whole file on open.
enum MarkdownPreviewChunker {
    /// Returns nil when the file should render as one document: at or under the
    /// splitter's chunk size, or without a safe boundary to split on.
    static func chunks(for content: String) -> [MarkdownPreviewChunk]? {
        guard content.count > StreamingMarkdownBlockSplitter.stableChunkTargetCharacterCount else { return nil }
        let segments = StreamingMarkdownBlockSplitter.split(content)
        var texts = segments.stableChunks.map(\.text)
        if !segments.activeMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(segments.activeMarkdown)
        }
        guard texts.count > 1 else { return nil }

        return texts.indices.map { index in
            MarkdownPreviewChunk(
                id: index,
                text: texts[index],
                topSpacing: index == 0 ? 0 : seamSpacing(after: texts[index - 1], before: texts[index])
            )
        }
    }

    /// MarkdownUI drops a document's outer block margins, so each seam restores the gap
    /// one document would draw: the larger of the previous block's bottom margin and the
    /// next block's top margin. Values mirror `MarkdownUI.Theme.chat` in MarkdownRenderer.
    static func seamSpacing(after previous: String, before next: String) -> CGFloat {
        max(bottomMargin(ofLastBlockIn: previous), topMargin(ofFirstBlockIn: next))
    }

    private static func bottomMargin(ofLastBlockIn text: String) -> CGFloat {
        let lines = trimmedLines(in: text)
        guard let lastIndex = lines.lastIndex(where: { !$0.isEmpty }) else { return 16 }
        let last = lines[lastIndex]
        if isFenceDelimiter(last) { return 12 }
        // `---` directly under text is a setext heading underline, not a rule.
        let isRule = isThematicBreak(last) && (lastIndex == 0 || lines[lastIndex - 1].isEmpty)
        return isRule ? 24 : 16
    }

    private static func topMargin(ofFirstBlockIn text: String) -> CGFloat {
        guard let first = trimmedLines(in: text).first(where: { !$0.isEmpty }) else { return 0 }
        if isHeading(first) || isThematicBreak(first) { return 24 }
        return isFenceDelimiter(first) ? 4 : 0
    }

    private static func trimmedLines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isFenceDelimiter(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func isHeading(_ line: String) -> Bool {
        let markers = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markers) else { return false }
        return line.dropFirst(markers).first.map(\.isWhitespace) ?? true
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }
}

enum FilePreviewContent {
    case text(FileResponse)
    case image(ImageFilePreview)
    case audio(Data)
    case unavailable(String)
}

struct ImageFilePreview {
    let data: Data
    let originalByteCount: Int
}

struct FileExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
    let isImage: Bool
    let isVideo: Bool
}

enum FileExportError: LocalizedError {
    case missingSessionID
    case missingPath

    var errorDescription: String? {
        switch self {
        case .missingSessionID:
            String(localized: "Session ID is missing.")
        case .missingPath:
            String(localized: "File path is missing.")
        }
    }
}
