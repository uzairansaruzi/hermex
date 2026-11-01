import SwiftUI
import UIKit

/// One run, read in full: webui's output file, or a Hermes run's final reply. A Hermes
/// script-only run shows the preview its row carries, and says when the host cut it short.
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
                        VStack(alignment: .leading, spacing: 12) {
                            if run.isScriptOutputCut {
                                Text("The server shows only the start of this run's output.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text(text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
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
                        Text("No output for this run.")
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
        guard let date = run.date else { return run.filename }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The loaded text, but only if it is this run's.
    private var matchingText: String? {
        guard let output, output.filename == run.filename else { return nil }
        return output.text
    }
}
