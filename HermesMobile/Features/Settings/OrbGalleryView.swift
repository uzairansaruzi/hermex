#if DEBUG
import SwiftUI

/// Every orb state, large, with its tool-mapping rationale
/// (`--surface-gallery-page 19`).
///
/// Rendered big enough to judge the animation itself — at the production 20pt
/// the difference between two dot fields is hard to see, which is how a
/// mis-ported engine could slip through.
struct OrbGalleryView: View {
    private let specimens: [(ThinkingOrbState, String, String)] = [
        (.thinking, "thinking", "reasoning streams"),
        (.searching, "searching", "read · grep · list · web · find"),
        (.writing, "writing", "write · edit · patch · rename"),
        (.connecting, "connecting", "http · api · clone · push · deploy"),
        (.shaping, "shaping", "shell · exec · run · git · python"),
        (.solving, "solving", "test · build · lint · diff · verify"),
        (.listening, "listening", "approval · clarify · confirm"),
        (.working, "working", "residual — anything unmatched")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ORB STATES · \(specimens.count)")
                    .font(.caption.weight(.bold))

                ForEach(Array(specimens.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 14) {
                        ThinkingOrbView(state: item.0, size: 44)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.1)
                                .font(.footnote.weight(.semibold))
                            Text(item.2)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
