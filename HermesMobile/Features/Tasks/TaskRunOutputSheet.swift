import SwiftUI
import UIKit

/// One past run, read in full.
///
/// The sheet renders `output` only when it belongs to the run on screen, so a
/// slow request that lands after the user has moved to another run can never
/// put the wrong transcript under the wrong heading.
struct TaskRunOutputSheet: View {
    let run: CronRunHistoryItem
    let output: CronRunOutput?
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let text = matchingText, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else if isLoading {
                    ProgressView("Loading output...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Could Not Load Output", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again", action: retry)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Empty Output", systemImage: "doc.text")
                    } description: {
                        Text("This run finished without writing anything.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = matchingText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(matchingText?.isEmpty != false)
                }
            }
        }
    }

    private var title: String {
        guard let modified = run.modified else { return run.filename }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }

    /// The loaded text, but only if it is this run's.
    private var matchingText: String? {
        guard let output, output.filename == run.filename else { return nil }
        return output.text
    }
}
