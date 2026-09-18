import SwiftUI

/// Bot snapshots render text synchronously, including during a live response.
/// Reuse the transcript parser; only the download and preview ownership are Bot-specific.
struct BotArtifactMessageView: View {
    let message: ChatMessage
    let model: BotConversation
    @State private var preview: TranscriptMediaPreviewItem?
    @State private var previewContext: BotArtifactContext?

    var body: some View {
        Group {
            if message.role == "user" {
                MessageBubbleView(
                    message: message,
                    transcriptMediaCacheNamespace: "\(model.server.absoluteString)|bot:\(model.connection.id.uuidString)",
                    textOnly: true
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(TranscriptMediaParser.segments(in: message.content ?? "", includesLocalFileLinks: true).enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .text(let text):
                            MarkdownRenderer(content: text)
                        case .media(let reference):
                            BotArtifactRow(reference: reference, model: model) {
                                previewContext = model.artifactContext
                                preview = TranscriptMediaPreviewItem(reference: reference)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let path = try? BotArtifactReference.path(url.absoluteString, address: model.connection.address) {
                previewContext = model.artifactContext
                preview = TranscriptMediaPreviewItem(reference: TranscriptMediaReference(rawReference: path))
                return .handled
            }
            return .systemAction
        })
        .sheet(item: $preview) { item in
            BotArtifactPreview(reference: item.reference) {
                guard let context = previewContext else { throw BotFailure.stale }
                return try await model.artifactData(path: item.reference.rawReference, context: context)
            }
        }
        .onChange(of: model.artifactContext) { _, _ in preview = nil; previewContext = nil }
    }
}

private struct BotArtifactRow: View {
    let reference: TranscriptMediaReference
    let model: BotConversation
    let open: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 210, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Label(reference.displayName, systemImage: reference.isAudioCandidate ? "waveform" : (reference.isRasterImageCandidate ? "photo" : "doc"))
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.chatTactile(.thumbnail))
        .accessibilityLabel("Open attachment \(reference.accessibilityName)")
        .task(id: LoadIdentity(context: model.artifactContext, reference: reference.rawReference)) {
            image = nil
            guard reference.isRasterImageCandidate, let context = model.artifactContext,
                  let data = try? await model.artifactData(path: reference.rawReference, context: context),
                  let thumbnail = await ImagePreviewDownsampler.previewDataAsync(from: data, maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize),
                  !Task.isCancelled, context == model.artifactContext else { return }
            image = UIImage(data: thumbnail)
        }
    }

    private struct LoadIdentity: Hashable {
        let context: BotArtifactContext?
        let reference: String
    }
}
