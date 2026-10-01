/**
 * Hermex adopted Attachment component-size tokens.
 *
 * Mirrors `HermesAttachmentSize` (HermesMobile/Config/HermesSpacing.swift), adopted in the verified
 * local implementation branch alongside this catalog slice. These are fixed component dimensions
 * for the Attachment family specifically: not a new global spacing/radius scale (see
 * `tokens/scales.ts` for those, which this module does not import from) and not catalog chrome.
 * Attachment's own file-type icon renders at `HermesIconSize.extraLarge`, owned by the canonical
 * `./hermesIconSize` module, not duplicated here.
 */

export const HERMES_ATTACHMENT_SIZE = {
  compactPreview: 30,
  messageGridCell: 118,
  composerImage: 96,
  composerImageAccessibility: 108,
  fileIconPanelWidth: 58,
  fileIconPanelHeight: 68,
  fileIconPanelWidthAccessibility: 76,
  fileIconPanelHeightAccessibility: 84,
  composerFileTextWidth: 128,
  composerFileTextWidthAccessibility: 160,
  composerFileTileWidth: 222,
  composerFileTileWidthAccessibility: 280,
  composerFileTileMinHeight: 92,
  composerFileTileMinHeightAccessibility: 112,
  composerStripHeight: 108,
  composerStripHeightAccessibility: 132,
  messageFileTextInset: 18,
  removeControl: 24,
  removeOverlap: 6,
  accessibilityVerticalPadding: 10,
} as const;

export type HermesAttachmentSizeKey = keyof typeof HERMES_ATTACHMENT_SIZE;
