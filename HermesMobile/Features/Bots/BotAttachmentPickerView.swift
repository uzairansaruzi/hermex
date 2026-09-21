import SwiftUI
import UniformTypeIdentifiers

enum BotAttachmentPicker: Equatable { case photos, files, camera }

/// Presentation only. The native + menu and attachment strip live in the same
/// composer positions as Sessions; imports still belong to the Bot draft.
struct BotAttachmentPickerPresentation: ViewModifier {
    let model: BotConversation
    @Binding var picker: BotAttachmentPicker?
    @State private var presentFilesAfterMediaPickerDismisses = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: presented(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let capacity = HermexAttachmentPickerPolicy.availableCapacity(
                        existingCount: model.attachments.items.count
                    )
                    guard urls.count <= capacity else {
                        model.attachments.report(BotAttachmentFailure.limit)
                        return
                    }
                    BotAttachmentPaste.files(urls, model: model)
                }
                else if case .failure(let error) = result,
                        (error as NSError).code != NSUserCancelledError { model.attachments.report(error) }
            }
            .background {
                HermexKeyboardRetainingOverlay(isPresented: presentsMedia.wrappedValue) {
                    HermexAttachmentPickerView(
                        imageCapacity: HermexAttachmentPickerPolicy.availableCapacity(
                            existingCount: model.attachments.items.count
                        ),
                        onChooseFiles: {
                            presentFilesAfterMediaPickerDismisses = true
                        },
                        onAdd: { media in
                            BotAttachmentPaste.media(media, model: model)
                        },
                        onDismiss: {
                            picker = nil
                        }
                    )
                }
                .frame(width: 0, height: 0)
            }
            .onChange(of: presentsMedia.wrappedValue) { _, isPresented in
                guard !isPresented, presentFilesAfterMediaPickerDismisses else { return }
                presentFilesAfterMediaPickerDismisses = false
                guard model.mayImportAttachments,
                      model.attachments.items.count < HermexAttachmentPickerPolicy.maximumBotAttachments
                else { return }
                picker = .files
            }
    }

    private var presentsMedia: Binding<Bool> {
        Binding(
            get: { picker == .photos || picker == .camera },
            set: { isPresented in
                if !isPresented, (picker == .photos || picker == .camera) {
                    picker = nil
                }
            }
        )
    }

    private func presented(_ value: BotAttachmentPicker) -> Binding<Bool> {
        Binding(get: { picker == value }, set: { if $0 { picker = value } else if picker == value { picker = nil } })
    }
}

@MainActor enum BotAttachmentPaste {
    static func media(_ media: [HermexPickedMedia], model: BotConversation) {
        Task {
            for item in media {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue { (item.data, item.filename) }
            }
        }
    }

    static func files(_ urls: [URL], model: BotConversation) {
        Task {
            for url in urls {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    try await Task.detached { try BotAttachmentDraft.readFile(url) }.value
                }
            }
        }
    }

    static func providers(_ providers: [NSItemProvider], model: BotConversation) {
        Task {
            for provider in providers {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    try await withCheckedThrowingContinuation { continuation in
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                                if let error { continuation.resume(throwing: error); return }
                                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                do {
                                    guard let url else { throw BotAttachmentFailure.unreadable }
                                    continuation.resume(returning: try BotAttachmentDraft.readFile(url))
                                } catch { continuation.resume(throwing: error) }
                            }
                        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                                if let error { continuation.resume(throwing: error); return }
                                guard let data else { continuation.resume(throwing: BotAttachmentFailure.unreadable); return }
                                continuation.resume(returning: (data, "image." + (UTType(type)?.preferredFilenameExtension ?? "jpg")))
                            }
                        } else { continuation.resume(throwing: BotAttachmentFailure.type) }
                    }
                }
            }
        }
    }

    static func images(_ images: [UIImage], model: BotConversation) {
        Task {
            for image in images {
                guard model.mayImportAttachments else { return }
                await model.attachments.importValue {
                    guard let data = image.jpegData(compressionQuality: 0.9) else { throw BotAttachmentFailure.unreadable }
                    return (data, "image.jpg")
                }
            }
        }
    }
}
