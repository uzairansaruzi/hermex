import SwiftUI

/// Draws the active streaming tail with per-word fade-in (issue #213).
///
/// `Text` resolves its full word-wrap layout before this renderer runs, so a
/// fading word already sits at its final position and never reflows mid-fade.
/// The renderer only repaints glyph slices at an opacity derived from when
/// their characters first appeared; persisted content is untouched.
struct StreamingTextFadeRenderer: TextRenderer {
    /// Wall-clock seconds supplied per frame by the driving `TimelineView`;
    /// frame delivery is guaranteed there, so no `Animatable` interpolation
    /// is involved (`AnimatableData` stays `EmptyAnimatableData`).
    var clock: TimeInterval
    let store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                ChatPerformanceInstrumentation.shared.record(.fadeDraws)
            }
        }
        // First pass: hand every slice to the reveal queue in reading order,
        // so glyphs that arrived together cascade instead of fading as one
        // chunk. A ligature slice can span several characters; the newest one
        // keys the fade so a boundary slice never pops ahead of its word.
        var orderedKeys: [Text.Layout.CharacterIndex] = []
        for line in layout {
            for run in line {
                for slice in run {
                    if let key = slice.characterIndices.max() {
                        orderedKeys.append(key)
                    }
                }
            }
        }
        store.register(orderedKeys, clock: clock)

        for line in layout {
            for run in line {
                for slice in run {
                    let opacity = store.opacity(
                        for: slice.characterIndices.max(),
                        clock: clock
                    )

                    if opacity >= 1 {
                        ctx.draw(slice)
                    } else if opacity > 0 {
                        var faded = ctx
                        faded.opacity = opacity
                        faded.draw(slice)
                    }
                }
            }
        }

        store.finishBaseline()
    }
}
