/**
 * Live/recon previews for the reusable-component-family catalog entries added alongside the
 * production token system (Avatar's bot-mark addition, Divider, Tag, Shimmer/Skeleton,
 * List/ListItem, Banner, Attachment, Inline Reference Link, and the Disclosure Row / Reference
 * Chip / Composer / Transcript Activity secondary patterns). Extracted out of hermesSections.tsx
 * (same reasoning as HermesSemanticColorReference.tsx / HermesIconReference.tsx /
 * HermesMotionReference.tsx) so that file stays a metadata/SectionDef list, not a growing pile of
 * preview JSX.
 *
 * Where the generic component library IS the real shared primitive (Divider, Shimmer, List,
 * ListItem, Badge, Button, Banner), these previews render it directly. Where Hermex's own SwiftUI
 * chrome has no generic equivalent (the exact Tag size/opacity table, Attachment, Inline Reference
 * Link, the static bot mark, the Composer mock), previews are hand-built "recon" approximations of
 * the real values — the same convention hermesSections.tsx's own local `recon` StyleSheet already
 * uses, deliberately not this repo's own template tokens.
 */
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { AccessibilityInfo, Animated, Platform, View, Text, Pressable, ScrollView, StyleSheet, TextInput } from 'react-native';
import { AccordionList, Avatar, Badge, Banner, Button, Card, Checkbox, Divider, List, ListItem, Radio, Shimmer, SkeletonGroup, Toast, Tooltip, TopNav } from '../../components';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { DS_ICON_SIZE, DS_RADIUS, DS_SPACING } from '../../../tokens';
import { CATALOG_SPECIMEN_GRID_GAP } from '../tokens';
import { CatalogSpecimenHeader } from '../CatalogSpecimenHeader';
import { HERMES_COLOR_RAMPS, HERMES_SEMANTIC_COLORS } from './hermesColorCatalogData';
import { HERMES_ATTACHMENT_SIZE } from './hermesAttachmentSize';
import { HERMES_ICON_SIZE } from './hermesIconSize';
import { HERMES_ICON_AVATAR_PAIRING } from './hermesIconSize';
import { HERMES_MOTION_BUNDLES } from './hermesTokenProposal';


const preview = StyleSheet.create({
  stack: { gap: 12 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 12, alignItems: 'flex-start' },
  // #607 round-3 correction: the shared 40px specimen-grid gap (CATALOG_SPECIMEN_GRID_GAP), the same
  // constant SectionBlock's own itemized exampleGrid imports, so the two catalogs' specimen grids
  // can never drift apart.
  specimenGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: CATALOG_SPECIMEN_GRID_GAP, alignItems: 'flex-start', justifyContent: 'flex-start' },
  // Every specimen column owns 16px internal padding (matches SectionBlock's own specimenColumn).
  specimenGroup: { flexBasis: 320, flexGrow: 1, maxWidth: 402, minWidth: 0, gap: 12, padding: 16 },
  // Screen-fill intent (PreviewSpecimen's `fill` prop) — explicit `alignItems: 'stretch'` for a
  // block-level component (Accordion List, Attachment, Banner, Composer/Toolbar, Input/Search, Lists,
  // Selection Sheet, Toast, Top Nav) that should stretch to the column's inner content width instead
  // of shrink-wrapping. Every View already defaults to 'stretch', so this mainly documents intent;
  // a handful of recon components (e.g. Top Nav's shell) also switch their own fixed width to '100%'
  // under this same flag — see their own call sites.
  specimenGroupFill: { alignItems: 'stretch' },
  caption: { fontSize: 11, color: '#8a8a8a', lineHeight: 16 },
  // #607 round-3 correction: catalog-authored explanation copy moved behind PreviewSpecimen's
  // `details` prop uses this distinct style — visually identical to `caption` above, but kept as its
  // own identifier so a specimen's `details` content is never confused with (or accidentally left
  // behind as) inline main-surface caption text.
  detailsText: { fontSize: 11, color: '#8a8a8a', lineHeight: 16 },
  label: { fontSize: 11, fontWeight: '700', color: '#1c1c1e' },

  // Divider
  dividerCard: { width: 220, gap: 8, padding: 12, borderRadius: 12 },
  dividerLightCard: { backgroundColor: '#ffffff' },
  dividerDarkCard: { backgroundColor: '#1c1c1e' },

  // Tag
  tagRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, alignItems: 'center' },
  tagText: { fontWeight: '600' },

  // Buttons — Hermex Brand Primary and Adaptive Glass compose shared tokens over native controls.
  buttonBrandPrimary: { backgroundColor: HERMES_COLOR_RAMPS.Gold[500] },
  buttonBrandPrimaryLabel: { color: '#000000' },
  buttonGlassSurface: { backgroundColor: 'rgba(240,240,245,0.85)', borderWidth: 1, borderColor: 'rgba(0,0,0,0.10)' },
  // Secondary keeps the same generic `secondary` fill as Neutral, plus this explicit hairline border —
  // the one visible difference HermexButtonStyle draws between its neutral and secondary emphases.
  buttonSecondaryBordered: { borderWidth: 1, borderColor: 'rgba(0,0,0,0.12)' },

  // Tooltip — a static reconstruction of the native .popover content surface: 12pt padding
  // (HermesSpacing.s12), 280pt max width, and a top arrow edge pointing back at the trigger.
  tooltipSurfaceWrap: { alignItems: 'flex-start', gap: 0 },
  tooltipArrow: {
    width: 0, height: 0, marginLeft: 16,
    borderLeftWidth: 6, borderRightWidth: 6, borderBottomWidth: 6,
    borderLeftColor: 'transparent', borderRightColor: 'transparent', borderBottomColor: '#ffffff',
  },
  tooltipSurface: {
    maxWidth: 280, padding: 12, borderRadius: 10, backgroundColor: '#ffffff',
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
    shadowColor: '#000000', shadowOpacity: 0.12, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
  },
  tooltipSurfaceText: { fontSize: 15, color: '#1c1c1e' },

  // Bot mark
  botMarkPreview: {
    gap: 12, flexBasis: 220, flexGrow: 1, maxWidth: '100%', minWidth: 0,
  },
  botMarkBox: {
    width: 44, height: 44, borderRadius: 12, backgroundColor: '#2c2c2e',
    alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 6,
  },
  botEye: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#ffffff' },
  avatarSystemImageCell: { alignItems: 'center', gap: 4 },

  // Banner — HermexBanner.background paints .fullWidth as a bare, square-cornered, borderless tint
  // fill and .inset as a HermesRadius.card rounded rect with a hairline border; the generic Banner's
  // own calloutContainer is always rounded, so a full-width specimen overrides that corner radius to
  // 0 here rather than relying on margin alone to carry the distinction.
  bannerFullWidth: { borderRadius: 0 },

  // Attachment
  // Sized from HERMES_ATTACHMENT_SIZE.messageGridCell at each call site (not a fixed width/height
  // here) — this base style only supplies the shared look (surface, radius, border, content layout).
  // borderRadius reads DS_RADIUS.medium directly (the same token Card's own outer radius uses) —
  // never a second, independently-chosen Attachment-only radius value, per spec §4.3.
  tileBox: {
    borderRadius: DS_RADIUS.medium, backgroundColor: '#f2f2f7',
    alignItems: 'center', justifyContent: 'center', gap: 4, borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(0,0,0,0.10)',
  },
  tileName: { fontSize: 10, fontWeight: '500', color: '#1c1c1e', textAlign: 'center', paddingHorizontal: 6 },
  tileExt: { fontSize: 9, fontWeight: '700' },
  // Compact Card composition — the normal (non-mini) message/composer tile's outer surface, per
  // spec §4.3: the real Card component (density="compact" supplies the reduced, not default-16pt,
  // padding); this override style only replaces Card's own white/shadowed chrome with the tile's own
  // tinted, flat surface. The sent-message tile uses GridAttachmentCell's centered vertical anatomy;
  // the composer tile keeps its horizontal icon-panel/text anatomy.
  messageFileTile: {
    backgroundColor: '#f2f2f7', shadowOpacity: 0, elevation: 0,
    alignItems: 'center', justifyContent: 'center', gap: 4,
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },
  composerFileTile: {
    backgroundColor: '#f2f2f7', shadowOpacity: 0, elevation: 0,
    flexDirection: 'row', alignItems: 'center', gap: 8,
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },
  // Sized from HERMES_ATTACHMENT_SIZE.fileIconPanelWidth/fileIconPanelHeight at each call site.
  fileIconPanel: {
    borderRadius: 12, alignItems: 'center', justifyContent: 'center', gap: 2,
  },
  composerTileText: { flex: 1, gap: 2 },
  composerTileName: { fontSize: 11, fontWeight: '500', color: '#1c1c1e' },
  composerTileDetail: { fontSize: 10, color: '#6d6d72' },
  // Mini-preview thumbnail — deliberately NOT Card/Compact Card anatomy (30x30 is too small for
  // 16pt/12pt content padding to read as anything but a solid square); see spec §4.3. Sized from
  // HERMES_ATTACHMENT_SIZE.compactPreview at the call site.
  miniPreviewThumb: {
    borderRadius: 6, alignItems: 'center', justifyContent: 'center',
  },
  // Positioned from HERMES_ATTACHMENT_SIZE.removeOverlap at the call site.
  attachmentRemove: { position: 'absolute' },
  attachmentFailureBadge: { position: 'absolute', bottom: -4, right: -4 },

  // TopNav — a bounded, clipped frame so the full-width bar reads as one contained specimen rather
  // than stretching to the whole documentation column.
  topNavShell: {
    width: '100%', borderRadius: 12, overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },
  topNavActionButton: { minWidth: 44, minHeight: 44 },

  // Disclosure / Log Row
  logRow: {
    width: '100%', flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 32,
    paddingVertical: 4,
  },
  logIconSlot: { width: 20, alignItems: 'center' },
  logSummary: { flex: 1, fontSize: 13, color: '#1c1c1e' },
  // Trailing group order matches native exactly: chevron, then the compact status slot at the
  // extreme trailing edge — never a wide status word inboard of the chevron.
  logTrailingGroup: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  logStatusSlot: { width: 16, height: 16, alignItems: 'center', justifyContent: 'center' },
  logBody: {
    // 28pt body indent (iconWidth 20 + HermesSpacing.s8 8), matching TranscriptLogRowMetrics.bodyIndent.
    marginLeft: 28, marginTop: 4, padding: 8, borderRadius: 8,
    backgroundColor: 'rgba(0,0,0,0.04)', maxHeight: 60,
    borderLeftWidth: StyleSheet.hairlineWidth, borderLeftColor: 'rgba(0,0,0,0.12)',
  },
  logBodyText: { fontSize: 11, fontFamily: 'Menlo', color: '#3a3a3c' },

  // Composer Chip — an inline, text-embedded reference chip (production's real
  // ComposerChipRendering.swift), rendered as a small tinted pill within ordinary sentence text.
  composerChipRow: { flexWrap: 'wrap' },
  composerChipInline: {
    fontSize: 13, fontWeight: '600', color: HERMES_COLOR_RAMPS.Blue[700],
    backgroundColor: HERMES_COLOR_RAMPS.Blue[100], borderRadius: 6, paddingHorizontal: 4,
  },
  // Composer Toolbar — the elevated appearance's own adaptive surface/radius/shadow reconstruction.
  // Issue #607 round 3/4 correction: 24px radius (DS_RADIUS.large, matching native HermesRadius.r24)
  // and 8px all-around padding (DS_SPACING[400], matching native HermesSpacing.s8) — replacing the
  // superseded 12px radius and 16px padding.
  composerToolbarElevated: {
    borderRadius: DS_RADIUS.large, backgroundColor: '#ffffff', padding: DS_SPACING[400],
    shadowColor: '#000', shadowOpacity: 0.12, shadowRadius: 6, shadowOffset: { width: 0, height: 2 },
  },
  composerToolbarOverflowContent: { minWidth: 520, flexWrap: 'nowrap' },
  // DSR3-01: HermexComposerToolbarDivider — hairline width, HermesSpacing.s24 (24pt) visible height,
  // vertically centered, decorative/accessibility-hidden, scrolls with the toolbar's own content. A
  // caller inserts it explicitly between logical control groups; the toolbar never adds one itself.
  composerToolbarDivider: {
    width: StyleSheet.hairlineWidth, height: 24, backgroundColor: 'rgba(0,0,0,0.18)', alignSelf: 'center',
  },

  // Static Skeleton (production-faithful — no animation)
  skeletonFill: { backgroundColor: 'rgba(120,120,128,0.16)' },
  skeletonTextLine: { height: 12, borderRadius: 4, width: '100%' },
  skeletonCircle: { width: 40, height: 40, borderRadius: 20 },
  skeletonCapsule: { width: 72, height: 24, borderRadius: 999 },
  skeletonRect: { width: 120, height: 64, borderRadius: 0 },
  skeletonRoundedRect: { width: 120, height: 64, borderRadius: 12 },
  skeletonCard: { width: 200, height: 88, borderRadius: 16 },

  // Native iOS patterns and the Hermex-owned Segmented Control reconstruction.
  nativeSearchInput: { flex: 1, minWidth: 0, fontSize: 16, color: '#1c1c1e', paddingVertical: 0 },

  // Search — the custom Hermex-owned HermexSearchField reconstruction: own adaptive Neutral surface
  // and border (resting vs. focused vs. disabled) rather than a bare native `.searchable` mock.
  searchField: {
    width: '100%', minHeight: 44, flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingHorizontal: 12, borderRadius: DS_RADIUS.medium,
    backgroundColor: HERMES_COLOR_RAMPS.Neutral[100],
    // Resting/focused border roles mirror the shared HERMEX_SURFACE_BORDER_COLORS reconstruction
    // (Neutral[600]/[700]) instead of a locally conflicting mapping.
    borderWidth: 1, borderColor: HERMES_COLOR_RAMPS.Neutral[600],
  },
  searchFieldFocused: { borderColor: HERMES_COLOR_RAMPS.Neutral[700], borderWidth: 1.5 },
  searchFieldDisabled: { opacity: 0.62 },
  searchFieldInput: { flex: 1, minWidth: 0, fontSize: 16, color: '#1c1c1e', paddingVertical: 0 },
  // The independent 44pt hit target itself is applied inline at the clear control's call site (see
  // SearchFamilyGallery) so it stays a literal, checkable minWidth/minHeight pair. The glyph aligns
  // flush with the target's trailing edge (not centered) so the target can expand inward from there —
  // the field's own 12pt paddingHorizontal (searchField.paddingHorizontal above) alone then supplies
  // the same visible edge inset the leading magnifier glyph already gets from that same padding,
  // rather than a second, independently-tuned inset stacking on top of it.
  searchClearTarget: { alignItems: 'flex-end', justifyContent: 'center' },
  nativeFieldGroup: { gap: 4, width: 280 },
  // HermexTextInputShell renders the label as .subheadline.weight(.semibold) in .primary — a 15pt
  // semibold primary label, visibly above the footnote-weight helper/error line below the field.
  fieldLabel: { fontSize: 15, fontWeight: '600', color: '#1c1c1e' },
  nativeFieldInput: {
    minHeight: 44, fontSize: 16, color: '#1c1c1e', paddingHorizontal: 12, paddingVertical: 10,
    borderRadius: 10, backgroundColor: '#efeff4',
    // Resting border shares the same HERMEX_SURFACE_BORDER_COLORS.resting anchor (Neutral[600]) as
    // Search, instead of a borderless field.
    borderWidth: 1, borderColor: HERMES_COLOR_RAMPS.Neutral[600],
  },
  // Code Input — a decorative digit-box row layered under one transparent, full-bleed native
  // TextInput (the same ZStack-over-one-editor shape as native HermexCodeInput), never a second
  // editing surface. The box row is hidden from assistive technology on both native
  // (accessibilityElementsHidden/importantForAccessibility) and web — see its call site.
  codeInputStack: { height: 48, justifyContent: 'center' },
  codeInputRow: { position: 'absolute', left: 0, right: 0, flexDirection: 'row' },
  codeInputBox: {
    flex: 1, height: 48, borderRadius: DS_RADIUS.medium,
    backgroundColor: HERMES_COLOR_RAMPS.Neutral[100],
    borderWidth: 1, borderColor: HERMES_COLOR_RAMPS.Neutral[600],
    alignItems: 'center', justifyContent: 'center',
  },
  codeInputBoxError: { borderColor: HERMES_COLOR_RAMPS.Red[700], borderWidth: 1.5 },
  codeInputBoxDisabled: { opacity: 0.55 },
  codeInputBoxText: { fontSize: 20, fontWeight: '600', color: '#1c1c1e' },
  // The one real editing surface: transparent so the decorative boxes above show through, but still
  // the sole target that receives focus, keystrokes, and accessibility.
  codeInputEditor: { ...StyleSheet.absoluteFill, opacity: 0 },
  codeInputErrorText: { color: HERMES_COLOR_RAMPS.Red[700] },
  composerTextInputRow: {
    minHeight: 44, flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingHorizontal: 12, borderRadius: 10, backgroundColor: 'rgba(120,120,128,0.16)',
  },

  // Bottom Sheet — a bounded, clipped frame (same reasoning as topNavShell above) so the sheet's
  // TopNav header, unconstrained body slot, and pinned footer read as one contained specimen rather
  // than stretching to the whole documentation column. Shown inline for inspection, never as a real
  // overlay/backdrop — production always presents this content through native `.sheet`.
  bottomSheetSpecimen: { width: 320, gap: 8 },
  bottomSheetShell: {
    width: '100%', borderRadius: 20, overflow: 'hidden',
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
    backgroundColor: '#ffffff',
  },
  bottomSheetBody: { padding: 16, gap: 8 },
  bottomSheetBodyText: { fontSize: 13, color: '#3a3a3c', lineHeight: 18 },
  // No borderTop here — HermexBottomSheet.swift pins the footer with a plain .safeAreaInset over
  // the bar material, with no Divider or border of its own.
  bottomSheetFooter: {
    flexDirection: 'row', gap: 8, padding: 16,
  },
  bottomSheetFooterVertical: { flexDirection: 'column' },
  bottomSheetFooterButton: { flex: 1 },
  bottomSheetFooterButtonFull: { width: '100%' },

  // Dialog — a static dimmed backdrop behind a centered card, shown inline for inspection (same
  // reasoning as the Bottom Sheet shell above): production never renders this as literal RN, and
  // the real backdrop never dismisses the dialog either way.
  dialogSpecimen: { width: 300, gap: 8 },
  dialogBackdrop: {
    width: '100%', minHeight: 220, borderRadius: 20, overflow: 'hidden',
    backgroundColor: 'rgba(0,0,0,0.4)', alignItems: 'center', justifyContent: 'center', padding: 20,
  },
  // DSR3-05: gap 16, matching native HermexDialogMetrics.contentSpacing (HermesSpacing.s16) — the
  // stale 12px gap here was the only actual drift; native spacing was already correct.
  dialogCard: {
    width: '100%', borderRadius: 20, backgroundColor: '#ffffff', padding: 20, gap: 16,
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },
  dialogHeaderRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  dialogHeading: { flex: 1, fontSize: 15, fontWeight: '600', color: '#1c1c1e' },
  // 24pt visual matches HermexButtonSize.extraSmall.minHeight; the glass surface reuses the same
  // translucent composition as buttonGlassSurface (Buttons — Adaptive Glass) rather than a bespoke tint.
  dialogCloseButton: {
    width: 24, height: 24, borderRadius: 12,
    alignItems: 'center', justifyContent: 'center',
  },
  dialogBodyText: { fontSize: 13, color: '#3a3a3c', lineHeight: 18 },
  dialogFooter: { flexDirection: 'row', gap: 8, justifyContent: 'flex-end' },
  dialogFooterVertical: { flexDirection: 'column', justifyContent: 'flex-start' },
  // Issue #607 final correction pass: HermexDialog.footerLayout's horizontal case adds a leading
  // Spacer so the caller's own intrinsically-sized actions hug the trailing edge — it never stretches
  // them. dialogFooter's own justifyContent: 'flex-end' already reproduces that hugging; this style
  // intentionally stays empty (no flex: 1) so the buttons size to their own content.
  dialogFooterButton: {},
  dialogFooterButtonFull: { width: '100%' },

  // Popover Menu — a static trigger + floating compactOverlay List/ListItem card, shown inline for
  // inspection (same reasoning as the Dialog/Bottom Sheet shells above): production never mounts
  // this as literal RN, and the real menu is always trigger-anchored, not laid out in document flow.
  // `flexBasis`/`flexGrow`/`maxWidth`/`minWidth` matches the same responsive convention as
  // `botMarkPreview` above — a specimen shrinks to fit a narrow section instead of assuming 220px
  // always fits. `position: 'relative'` anchors the interactive demo's own backdrop (below).
  popoverSpecimen: { flexBasis: 220, flexGrow: 1, maxWidth: '100%', minWidth: 0, gap: 8, position: 'relative' },
  popoverAnchorRow: { flexDirection: 'row' },
  popoverAnchorRowTrailing: { justifyContent: 'flex-end' },
  popoverTrigger: {
    width: 32, height: 32, borderRadius: 16, backgroundColor: 'rgba(0,0,0,0.08)',
    alignItems: 'center', justifyContent: 'center',
  },
  popoverTriggerText: { fontSize: 15, fontWeight: '700', color: '#1c1c1e' },
  // `position: 'relative'` gives the surface its own stacking layer so it paints above the
  // interactive demo's `position: 'absolute'` backdrop regardless of DOM order (CSS always stacks
  // positioned elements above static ones); harmless for the static specimens, which have no backdrop.
  // DSR3-06: one 16px shell inset (HermexPopoverMenuMetrics.contentPadding), applied once here on
  // the surface — `popoverList` below adds no horizontal inset of its own, avoiding a stacked
  // 16+12 double inset. Native additionally composes ListItem's own rows with `contentInset: .none`
  // for the same reason; this generic reconstruction's ListItem has no equivalent inset toggle, so
  // its own fixed row inset is what renders inside this one 16px boundary.
  popoverSurfaceBelow: {
    position: 'relative', borderRadius: 16, backgroundColor: '#ffffff', overflow: 'hidden', padding: 16,
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
    shadowColor: '#000000', shadowOpacity: 0.16, shadowRadius: 12, shadowOffset: { width: 0, height: 4 },
  },
  popoverSurfaceAbove: {
    position: 'relative', borderRadius: 16, backgroundColor: '#ffffff', overflow: 'hidden', padding: 16,
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
    shadowColor: '#000000', shadowOpacity: 0.16, shadowRadius: 12, shadowOffset: { width: 0, height: -4 },
  },
  // No horizontal padding here — the 16px shell inset lives on the surface above; adding one here too
  // would stack a second, doubled inset on top of it.
  popoverList: { width: '100%' },
  // The interactive demo's own outside-tap dismissal target — `StyleSheet.absoluteFill`, the same
  // convention Dialog/BottomSheet use for their own backdrops (bounded to this demo's own card, not
  // the full page, since this is an inline catalog specimen rather than a real floating overlay).
  popoverBackdrop: { ...StyleSheet.absoluteFill },
  compactOverlayDemoList: {
    borderRadius: 16, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },

  segmentedFixedTrackWrapper: { width: 280 },
  // A distinct 40pt visual-track background layer (the 36pt selected pill plus one HermesSpacing.s2
  // padding step above and below) — separate from the 44pt interactive row it sits behind, which
  // keeps owning the full touch target.
  segmentedFixedVisualTrack: {
    position: 'absolute', left: 0, right: 0, top: 2, height: 40, borderRadius: 999,
    backgroundColor: 'rgba(120,120,128,0.16)',
  },
  segmentedFixedTrack: { flexDirection: 'row', gap: 4, paddingHorizontal: 2 },
  segmentedTouchTarget: { minHeight: 44, justifyContent: 'center' },
  segmentedPill: {
    height: 36, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingHorizontal: 12, borderRadius: 999,
  },
  segmentedFixedOption: { flex: 1 },
  scrollingSegmentText: { fontSize: 14, color: '#6d6d72' },
  scrollingSegmentTextSelected: { color: '#1c1c1e', fontWeight: '600' },

  // Composer pattern mock
  composerSurface: {
    width: 320, borderRadius: 24, backgroundColor: 'rgba(240,240,245,0.85)', padding: 10, gap: 8,
    borderWidth: 1, borderColor: 'rgba(0,0,0,0.08)',
  },
  composerInputRow: {
    minHeight: 36, borderRadius: 18, backgroundColor: '#ffffff', paddingHorizontal: 12,
    justifyContent: 'center', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.10)',
  },
  composerInputText: { fontSize: 13, color: '#8a8a8a' },
  composerActionsRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  composerValidationText: { fontSize: 11, color: '#FF3B30', fontWeight: '600' },
  composerSendButton: {
    width: 32, height: 32, borderRadius: 16, backgroundColor: '#3478F6',
    alignItems: 'center', justifyContent: 'center',
  },
  composerSendGlyph: { color: '#ffffff', fontSize: 14, fontWeight: '700' },

  // SessionListItem — streaming/attention affordances beyond plain ListItem
  streamDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#34C759' },
  attentionText: { fontSize: 11, color: '#FF3B30', fontWeight: '600' },

  // DSR3-07: ListItem's rounded, non-scaling pressed reconstruction — the generic template
  // ListItem's own pressed style is a plain full-bleed rectangle fill; this recon demonstrates the
  // real ListItemButtonStyle instead: a rounded (ListItemMetrics.cornerRadius) Neutral pressed fill,
  // no spatial scale. `listItemPressedRowInsetNone` demonstrates `contentInset: .none` (Popover
  // Menu's own composition) beside the `.standard` default.
  listItemPressedRow: { borderRadius: 12, paddingVertical: 12, paddingHorizontal: 16 },
  listItemPressedRowInsetNone: { paddingHorizontal: 0 },
  listItemPressedRowActive: { backgroundColor: 'rgba(120,120,128,0.16)' },
  // Native ListItem's default selected state: the whole row becomes a Color.primary pill and both
  // title and automatic checkmark invert to the system background color. This explicit reconstruction
  // is necessary because the shared generic RN ListItem's `selected` prop carries semantics only.
  listItemSelectedPill: {
    minHeight: 48, marginHorizontal: 12, paddingHorizontal: 12, borderRadius: 12,
    flexDirection: 'row', alignItems: 'center', gap: 12, backgroundColor: '#1c1c1e',
  },
  listItemSelectedTitle: { flex: 1 },
  listItemSelectedForeground: { fontSize: 16, color: '#ffffff' },
  // contentInset: .none on a real ListItem row — overrides the row's own default horizontal padding
  // so the s12-vs-none difference is visible at rest, the same composition Popover Menu uses.
  listItemContentInsetNone: { paddingHorizontal: 0 },

  // Checkbox/Radio — component-scoped adaptive Neutral selected-fill swatch (same Light/Dark frame precedent
  // as HermesSemanticColorReference.tsx's SampleFrame, kept local since it's a one-off two-frame
  // pair rather than a full role gallery).
  adaptiveSwatchCell: { alignItems: 'center', gap: 4 },
  adaptiveSwatchFrame: {
    width: 64, height: 48, alignItems: 'center', justifyContent: 'center', borderRadius: 8,
  },
  adaptiveSwatchFrameLight: { backgroundColor: '#F2F2F7', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.08)' },
  adaptiveSwatchFrameDark: { backgroundColor: '#1C1C1E' },
  adaptiveSwatchSquare: { width: 20, height: 20, borderRadius: 4 },
  adaptiveSwatchCircle: { width: 20, height: 20, borderRadius: 10 },
  adaptiveSwatchLabel: { fontSize: 9, fontWeight: '700', color: '#8a8a8a', fontFamily: 'Menlo' },
});

function PreviewSpecimenGrid({ children }: { children: ReactNode }) {
  return <View style={preview.specimenGrid}>{children}</View>;
}

/** One bounded, 402px-capped, 16px-padded specimen column — the main gallery surface shows only
 *  `name` and the rendered `children`; any catalog-authored explanation/caption goes in `details`,
 *  rendered exclusively inside the shared `CatalogSpecimenHeader`'s anchored Details popover, never
 *  inline. `fill` is this specimen's screen-fill intent: true for a component meant to occupy a
 *  phone/screen row (Accordion List, Attachment, Banner, Composer/Toolbar, Input/Search, Lists,
 *  Selection Sheet, Toast, Top Nav), which should stretch to the column's own inner content width;
 *  omitted (default false) for a compact, intrinsically-sized specimen. Derives its name/caption from
 *  explicit props rather than inspecting `children` — the previous inline `<Text style={preview
 *  .label}>`/`<Text style={preview.caption}>` convention this replaces relied on visible string
 *  content and child order, which this API makes structural instead. */
function PreviewSpecimen({
  name,
  details,
  fill,
  children,
}: {
  name: string;
  details?: ReactNode;
  fill?: boolean;
  children: ReactNode;
}) {
  return (
    <View style={[preview.specimenGroup, fill && preview.specimenGroupFill]}>
      <CatalogSpecimenHeader name={name} details={details} />
      {children}
    </View>
  );
}

// The approved Neutral color mapping (DSF-08/DSF-09, corrected), mirroring native
// HermexSelectionControlColors: every Hermex Radio/Checkbox specimen below passes this instead of
// the generic template's default DS_SEMANTIC.emphasis.info blue. Light-appearance values only,
// matching HermesColorRamp.Neutral's light anchor (.s950/.s50/.s500) — the gallery renders one
// static appearance; dark adaptation is documented by the swatch below, not asserted by these
// specimens themselves. unselectedBorder was originally Neutral.s400 (#AEAEB1); the review measured
// that light anchor at ~2.1:1 against the light primary surface, below the 3:1 non-text boundary
// threshold (WCAG 1.4.11), and corrected it to the contrast-validated Neutral.s500 (#8E8E93).
const HERMEX_SELECTION_CONTROL_COLORS = {
  selected: '#2D2D2F',
  selectedForeground: '#F9F9FA',
  unselectedBorder: '#8E8E93',
};

// ─── Checkbox/Radio — component-scoped adaptive Neutral selected-fill demo ─────
// The approved light/dark pair is Neutral.s950 / Neutral.s50, not Color.primary's pure black/white
// and not a fixed accent. Reuse the same Hermex selection-control mapping as every real specimen.
function AdaptiveSelectedFillSwatch({ shape }: { shape: 'square' | 'circle' }) {
  const fill = shape === 'circle' ? preview.adaptiveSwatchCircle : preview.adaptiveSwatchSquare;
  return (
    <View style={preview.row}>
      <View style={preview.adaptiveSwatchCell}>
        <View style={[preview.adaptiveSwatchFrame, preview.adaptiveSwatchFrameLight]}>
          <View style={[fill, { backgroundColor: HERMEX_SELECTION_CONTROL_COLORS.selected }]} />
        </View>
        <Text style={preview.adaptiveSwatchLabel}>Light · {HERMEX_SELECTION_CONTROL_COLORS.selected}</Text>
      </View>
      <View style={preview.adaptiveSwatchCell}>
        <View style={[preview.adaptiveSwatchFrame, preview.adaptiveSwatchFrameDark]}>
          <View style={[fill, { backgroundColor: HERMEX_SELECTION_CONTROL_COLORS.selectedForeground }]} />
        </View>
        <Text style={preview.adaptiveSwatchLabel}>Dark · {HERMEX_SELECTION_CONTROL_COLORS.selectedForeground}</Text>
      </View>
    </View>
  );
}

// ─── Avatar umbrella — static bot mark ───────────────────────────────────────
export function BotMarkPreview() {
  return (
    <View style={preview.botMarkPreview}>
      <View style={preview.botMarkBox}>
        <View style={preview.botEye} />
        <View style={preview.botEye} />
      </View>
      <Text style={preview.caption}>
        Static illustration only — BotAnimatedFaceView's blink/idle timeline and
        BotInteractiveFaceView's drag-to-gaze/tap-to-react behavior aren't reconstructed here.
      </Text>
    </View>
  );
}

// ─── Avatar — system-image identity (production HermexAvatar, used inside Content Unavailable) ──
// Driven directly off HERMES_ICON_AVATAR_PAIRING (the same source HermesIconReference's own
// IconAvatarPairingGallery reads) so the three approved avatar/icon diameters can't drift into a
// second, hand-typed copy here. Overrides the generic Avatar's default half-diameter icon ratio via
// `iconSize`, matching production HermexAvatar's fixed pairing rather than the template's own
// proportional default.
export function AvatarSystemImageIdentityPreview() {
  return (
    <View style={preview.row}>
      {Object.entries(HERMES_ICON_AVATAR_PAIRING).map(([key, { avatar, icon }]) => (
        <View key={key} style={preview.avatarSystemImageCell}>
          <Avatar size={avatar} iconSize={icon} iconName="menu" backgroundColor="#8E8E93" accessibilityLabel="No skills available" />
          <Text style={preview.caption}>{avatar} · icon {icon}</Text>
        </View>
      ))}
    </View>
  );
}

// ─── Divider ──────────────────────────────────────────────────────────────────
export function HermexDividerPreview() {
  return (
    <View style={preview.row}>
      <View style={[preview.dividerCard, preview.dividerLightCard]}>
        <Text style={[preview.label, { color: '#1c1c1e' }]}>Light background — default opacity</Text>
        <Divider />
        <Text style={preview.caption}>Component-owned default (0.72) — matches SettingsDivider</Text>
      </View>
      <View style={[preview.dividerCard, preview.dividerLightCard]}>
        <Text style={[preview.label, { color: '#1c1c1e' }]}>Light background — full strength</Text>
        <Divider opacity={1} />
        <Text style={preview.caption}>Caller override via the opacity prop — Card's footer divider</Text>
      </View>
      <View style={[preview.dividerCard, preview.dividerLightCard]}>
        <Text style={[preview.label, { color: '#1c1c1e' }]}>Light background — 16pt leading inset</Text>
        <View style={{ marginLeft: 16 }}>
          <Divider />
        </View>
        <Text style={preview.caption}>HermexDivider(leadingInset: HermesSpacing.s16) — row-aligned under a leading icon/avatar column</Text>
      </View>
      <View style={[preview.dividerCard, preview.dividerDarkCard]}>
        <Text style={[preview.label, { color: '#ffffff' }]}>Dark background</Text>
        <Divider style={{ backgroundColor: 'rgba(255,255,255,0.3)' }} />
        <Text style={[preview.caption, { color: '#8a8a8a' }]}>Adapts — never a fixed light-only gray</Text>
      </View>
    </View>
  );
}

// ─── Tag (display-only — was Status Capsule) ────────────────────────────────
function TagSwatch({
  label, tint, hPad, vPad, opacity = 0.12, iconGlyph,
}: { label: string; tint: string; hPad: number; vPad: number; opacity?: number; iconGlyph?: string }) {
  return (
    <View
      style={{
        flexDirection: 'row', alignItems: 'center', gap: 4,
        paddingHorizontal: hPad, paddingVertical: vPad, borderRadius: 999,
        backgroundColor: `${tint}${Math.round(opacity * 255).toString(16).padStart(2, '0')}`,
      }}
    >
      {iconGlyph ? <Text style={{ color: tint, fontSize: 10 }}>{iconGlyph}</Text> : null}
      <Text style={[preview.tagText, { color: tint, fontSize: 11 }]}>{label}</Text>
    </View>
  );
}

export function TagGallery() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>size: compact (8/2 padding)</Text>
      <View style={preview.tagRow}>
        <TagSwatch label="Cached" tint="#FF9500" hPad={8} vPad={2} />
        <TagSwatch label="Read-only" tint="#8E8E93" hPad={8} vPad={2} />
        <TagSwatch label="claude-code" tint="#3478F6" hPad={8} vPad={2} />
      </View>
      <Text style={preview.caption}>Sessions' Cached/Read-only/source tags, hidden from VoiceOver (decorative)</Text>
      <View style={preview.tagRow}>
        <TagSwatch label="Modified" tint="#FFCC00" hPad={8} vPad={2} opacity={0.18} />
        <TagSwatch label="Staged" tint="#34C759" hPad={8} vPad={2} opacity={0.18} />
      </View>
      <Text style={preview.caption}>Workspace/Git's change-kind tag (0.18 fill)</Text>
      <View style={preview.tagRow}>
        <TagSwatch label="Running" tint="#34C759" hPad={8} vPad={4} iconGlyph="●" />
        <TagSwatch label="Selected" tint="#3478F6" hPad={8} vPad={4} />
      </View>
      <Text style={preview.caption}>size: regular (8/4 padding, optional icon) — Tasks' status tag, Settings' profile tag</Text>
      <View style={preview.tagRow}>
        <TagSwatch label="Connected" tint="#34C759" hPad={12} vPad={8} />
      </View>
      <Text style={preview.caption}>size: prominent (12/8 padding, caption not caption2) — Settings' connection tag</Text>
      <Text style={[preview.label, { marginTop: 4 }]}>Every Tag instance above is display-only</Text>
      <Text style={preview.caption}>
        No Tag prop, example, or styling is interactive anywhere in this section — a tappable element
        uses a control or link component (see Buttons), never a styled Tag.
      </Text>
      <Text style={[preview.label, { marginTop: 4 }]}>Closest generic equivalent</Text>
      <View style={preview.tagRow}>
        <Badge variant="warning" label="Cached" />
        <Badge variant="neutral" label="Read-only" />
        <Badge variant="positive" label="Staged" />
      </View>
      <Text style={preview.caption}>
        Badge's 5 closed semantic variants are the closest generic model — production drives each
        tag from an arbitrary SwiftUI Color per status, not a fixed enum.
      </Text>
    </View>
  );
}

// ─── Button (decision + tactile cross-reference) ─────────────────────────────
export function ButtonDecisionAndTactilePreview() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Sizes (extra small → large)</Text>
      <View style={preview.row}>
        <Button label="XS" size="extraSmall" variant="secondary" onPress={() => {}} />
        <Button label="Small" size="small" variant="secondary" onPress={() => {}} />
        <Button label="Medium" size="medium" variant="secondary" onPress={() => {}} />
        <Button label="Large" size="large" variant="secondary" onPress={() => {}} />
      </View>
      <Text style={preview.caption}>
        Generic Button's own size scale, extended with `extraSmall` for a compact chrome-level
        action (never a primary action's only affordance) — the closest reusable model for
        Hermex's extra-small-through-large size requirement.
      </Text>
      <Text style={[preview.label, { marginTop: 8 }]}>Emphasis roles (Brand Primary/Neutral/Primary/Secondary/Destructive)</Text>
      <View style={preview.row}>
        <Button label="Brand primary" variant="primary" size="medium" style={preview.buttonBrandPrimary} textStyle={preview.buttonBrandPrimaryLabel} onPress={() => {}} />
        <Button label="Neutral" variant="secondary" size="medium" onPress={() => {}} />
        <Button label="Approve" variant="primary" size="medium" onPress={() => {}} />
        <Button label="Not now" variant="secondary" size="medium" style={preview.buttonSecondaryBordered} onPress={() => {}} />
        <Button label="Deny" variant="destructive" size="medium" onPress={() => {}} />
      </View>
      <Text style={preview.caption}>
        Brand Primary uses Hermex Gold 500 with Gold 600 pressed and a black label. Neutral composes
        the generic Button's `secondary` variant for its subtle fill, with no added border; Secondary
        reuses that same fill plus an explicit hairline border so the two stay visually distinct, the
        way native HermexButtonStyle's neutral (fill, no border) and secondary (fill, hairline border)
        emphases do; Primary/Destructive map onto the identically-named generic variants. Pending
        Request's Yes/No/Approve/Deny controls keep that decision mapping; the Tip Jar CTA uses Brand
        Primary.
      </Text>
      <Text style={[preview.label, { marginTop: 8 }]}>Adaptive Glass surface (composition, not a variant)</Text>
      <View style={preview.row}>
        <Button
          label="Glass"
          variant="secondary"
          size="medium"
          style={preview.buttonGlassSurface}
          onPress={() => {}}
        />
      </View>
      <Text style={preview.caption}>
        Glass is demonstrated here as a plain style composition on top of an existing variant — the
        same translucent surface as the Adaptive Glass Material entry — never a duplicated
        `variant="glass"` value or a second fallback/accessibility branch of its own.
      </Text>
      <Text style={[preview.label, { marginTop: 8 }]}>Content configurations</Text>
      <View style={preview.row}>
        <Button label="Label only" size="medium" variant="secondary" onPress={() => {}} />
        <Button showIcon showLabel={false} iconName="add" size="medium" variant="secondary" onPress={() => {}} />
        <Button label="Leading" showIcon iconName="add" iconPosition="leading" size="medium" variant="secondary" onPress={() => {}} />
        <Button label="Trailing" showIcon iconName="add" iconPosition="trailing" size="medium" variant="secondary" onPress={() => {}} />
      </View>
      <Text style={preview.caption}>label-only · icon-only · icon-leading · icon-trailing</Text>
      <Text style={[preview.label, { marginTop: 8 }]}>Disabled and pending</Text>
      <View style={preview.row}>
        <Button label="Disabled" size="medium" variant="secondary" disabled onPress={() => {}} />
        <Button label="Pending" size="medium" variant="secondary" loading onPress={() => {}} />
      </View>
      <Text style={[preview.label, { marginTop: 8 }]}>Press-only variants (HermexButtonPressOnlyStyle)</Text>
      <View style={preview.row}>
        <Button label="Send" showIcon showLabel={false} iconName="add" size="medium" onPress={() => {}} />
      </View>
      <Text style={preview.caption}>
        icon · compactControl · capsule · card · thumbnail — HermexButtonPressOnlyStyle's Chrome cases
        — apply press scale/opacity/shadow feedback to a native SwiftUI Button whose own shape/fill
        stays caller-owned, through the same applyingHermexButtonPressFeedback helper HermexButtonStyle's
        Standard Press Feedback uses (Reduce-Motion-safe; a spring/scale response drops out when
        Reduce Motion is on) — not a separate variant/label API, so they aren't reproduced as distinct
        RN examples here. Glass is a surface option composing Adaptive Glass (see that Material
        entry), not a duplicated fallback. Physical haptics remain a separate, opt-in concern from
        this press-feedback chrome.
      </Text>
    </View>
  );
}

// ─── Skeleton — static, production-faithful (no animation) ──────────────────
/**
 * Deliberately NOT the animated `Shimmer` component below — production's `SkeletonPlaceholder` is
 * static (a platform `.redacted(reason: .placeholder)` treatment), so this gallery reproduces that
 * static appearance for every required shape instead of introducing/describing continuous shimmer.
 */
export function HermesSkeletonGallery() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Text line</Text>
      <View style={{ gap: 6, width: 220 }}>
        <View style={[preview.skeletonFill, preview.skeletonTextLine]} />
        <View style={[preview.skeletonFill, preview.skeletonTextLine, { width: '70%' }]} />
      </View>
      <Text style={preview.label}>Circle / avatar · Block · Rounded rectangle · Content-shaped card</Text>
      <View style={preview.row}>
        <View style={[preview.skeletonFill, preview.skeletonCircle]} accessibilityLabel="Loading" />
        <View style={[preview.skeletonFill, preview.skeletonRect]} accessibilityLabel="Loading" />
        <View style={[preview.skeletonFill, preview.skeletonRoundedRect]} />
        <View style={[preview.skeletonFill, preview.skeletonCard]} />
      </View>
      <Text style={preview.label}>Grouped composition (one accessibility announcement)</Text>
      <SkeletonGroup style={{ flexDirection: 'row', gap: 10, alignItems: 'center', width: 240 }}>
        <View style={[preview.skeletonFill, preview.skeletonCircle, { width: 40, height: 40, borderRadius: 20 }]} />
        <View style={{ flex: 1, gap: 6 }}>
          <View style={[preview.skeletonFill, preview.skeletonTextLine]} />
          <View style={[preview.skeletonFill, preview.skeletonTextLine, { width: '60%' }]} />
        </View>
      </SkeletonGroup>
      <Text style={preview.caption}>
        Every shape here is static — no pulse, no loop — matching production's shared text-line,
        block, circle, and rounded-rectangle Skeleton shapes. Content-shaped cards keep
        `.skeletonPlaceholder()` when the final view already owns the right geometry. Reduce Motion
        needs no separate fallback here because nothing in this gallery ever animates.
      </Text>
    </View>
  );
}

// ─── Search — the custom Hermex-owned HermexSearchField/.hermexSearch foundation ─
const SEARCH_FAMILY_SAMPLE_SESSIONS = ['Refactor auth module', 'Investigate flaky test', 'Update onboarding copy'];

export function SearchFamilyGallery() {
  const [query, setQuery] = useState('');
  const [isFocused, setIsFocused] = useState(false);
  const [submitCount, setSubmitCount] = useState(0);
  const searchInputRef = useRef<TextInput>(null);
  const trimmed = query.trim().toLowerCase();
  const results = trimmed.length === 0
    ? SEARCH_FAMILY_SAMPLE_SESSIONS
    : SEARCH_FAMILY_SAMPLE_SESSIONS.filter((session) => session.toLowerCase().includes(trimmed));
  const submitUnit = submitCount === 1 ? 'time' : 'times';
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen name="Enabled — HermexSearchField" fill>
      <View
        style={[preview.searchField, isFocused && preview.searchFieldFocused]}
        accessibilityRole="search"
      >
        <Icon name="search" size={DS_ICON_SIZE.sm} color="#6d6d72" />
        <TextInput
          ref={searchInputRef}
          value={query}
          onChangeText={setQuery}
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          onSubmitEditing={() => setSubmitCount((count) => count + 1)}
          returnKeyType="search"
          placeholder="Search sessions"
          accessibilityLabel="Search sessions"
          style={preview.searchFieldInput}
        />
        {query.length > 0 && (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Clear search"
            style={[preview.searchClearTarget, { minWidth: 44, minHeight: 44 }]}
            onPress={() => {
              setQuery('');
              searchInputRef.current?.focus();
            }}
          >
            <Icon name="clear" size={DS_ICON_SIZE.sm} color="#6d6d72" />
          </Pressable>
        )}
      </View>
      <Text style={preview.caption}>Submitted {submitCount} {submitUnit}.</Text>

      {results.length > 0 ? (
        <View style={preview.stack}>
          {results.map((session) => (
            <Text key={session} style={preview.label}>{session}</Text>
          ))}
        </View>
      ) : (
        <Text style={preview.caption}>No results for “{query}”.</Text>
      )}

      </PreviewSpecimen>
      <PreviewSpecimen
        name="Disabled"
        fill
        details={
          <Text style={preview.detailsText}>
            The custom Hermex-owned `HermexSearchField` — its own adaptive Neutral surface and border
            (resting, focused, disabled), not a bare native `.searchable` reconstruction. Results, filtering,
            and the no-results state above stay caller-owned; the field itself only owns chrome, local
            focus, the clear control, and keyboard-submit wiring. `.hermexSearch(...)` composes this exact
            field as a persistent top content inset — it is not a second implementation.
          </Text>
        }
      >
      <View
        style={[preview.searchField, preview.searchFieldDisabled]}
        accessibilityRole="search"
        accessibilityState={{ disabled: true }}
      >
        <Icon name="search" size={DS_ICON_SIZE.sm} color="#6d6d72" />
        <TextInput
          value="Read only"
          editable={false}
          accessibilityLabel="Disabled search"
          style={preview.searchFieldInput}
        />
      </View>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// Reconstructs `HermexCodeInput`'s own shape: one real, transparent native `TextInput` — number-pad
// keyboard, one-time-code content type, ASCII-digit-only filtering, truncated to `length` — layered
// over a decorative digit-box row that mirrors its bound value. The box row is the only thing that's
// visible; it is hidden from assistive technology (accessibilityElementsHidden/
// importantForAccessibility) so the one TextInput stays the sole accessibility element, exactly as
// native HermexCodeInput exposes one grouped field behind its decorative boxes. Helper and error text
// stay mutually exclusive, matching HermexTextInputShell. No `onSubmitEditing`/completion callback is
// wired — reaching `length` digits here never implies auto-submit.
function HermexCodeInputSpecimen({
  title,
  length,
  initialValue = '',
  helperText,
  errorText,
  disabled = false,
}: {
  title: string;
  length: number;
  initialValue?: string;
  helperText?: string;
  errorText?: string;
  disabled?: boolean;
}) {
  const [code, setCode] = useState(initialValue);
  const spacing = length >= 7 ? 4 : 8;
  const digits = Array.from({ length }, (_, index) => code[index] ?? '');

  return (
    <View>
      <Text style={preview.caption}>{title}</Text>
      <View style={preview.codeInputStack}>
        <View
          style={[preview.codeInputRow, { gap: spacing }]}
          pointerEvents="none"
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
        >
          {digits.map((digit, index) => (
            <View
              key={index}
              style={[
                preview.codeInputBox,
                !!errorText && preview.codeInputBoxError,
                disabled && preview.codeInputBoxDisabled,
              ]}
            >
              <Text style={preview.codeInputBoxText}>{digit}</Text>
            </View>
          ))}
        </View>
        <TextInput
          value={code}
          onChangeText={(raw) => setCode(raw.replace(/[^0-9]/g, '').slice(0, length))}
          editable={!disabled}
          keyboardType="number-pad"
          textContentType="oneTimeCode"
          accessibilityLabel="Verification code"
          style={preview.codeInputEditor}
        />
      </View>
      {errorText ? (
        <Text style={[preview.caption, preview.codeInputErrorText]}>{errorText}</Text>
      ) : helperText ? (
        <Text style={preview.caption}>{helperText}</Text>
      ) : null}
    </View>
  );
}

// ─── Text Input — Hermex-owned HermexTextField/HermexSecureField/HermexCodeInput wrappers ─
export function HermexTextInputFamilyGallery() {
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  return (
    <View style={preview.stack}>
      <View style={preview.nativeFieldGroup}>
        <Text style={preview.label}>Default — HermexTextField</Text>
        <Text style={preview.fieldLabel}>Name</Text>
        <TextInput
          value={name}
          onChangeText={setName}
          placeholder="Enter your name"
          accessibilityLabel="Name"
          style={preview.nativeFieldInput}
        />
      </View>
      <View style={preview.nativeFieldGroup}>
        <Text style={preview.label}>Password — HermexSecureField</Text>
        <Text style={preview.fieldLabel}>Password</Text>
        <TextInput
          value={password}
          onChangeText={setPassword}
          placeholder="Enter your password"
          accessibilityLabel="Password"
          secureTextEntry
          style={preview.nativeFieldInput}
        />
      </View>
      <View style={[preview.nativeFieldGroup, { gap: 12 }]}>
        <Text style={preview.label}>Code — HermexCodeInput</Text>
        <Text style={preview.fieldLabel}>Verification code</Text>
        <HermexCodeInputSpecimen
          title="4 digits — partial"
          length={4}
          initialValue="12"
          helperText="Enter the 4-digit code."
        />
        <HermexCodeInputSpecimen
          title="6 digits — complete"
          length={6}
          initialValue="123456"
          helperText="Enter the 6-digit code."
        />
        <HermexCodeInputSpecimen
          title="6 digits — error"
          length={6}
          initialValue="1234"
          errorText="Enter all 6 digits."
        />
        <HermexCodeInputSpecimen
          title="8 digits — disabled"
          length={8}
          initialValue="12345678"
          disabled
          helperText="Enter the 8-digit code."
        />
      </View>
      <Text style={preview.caption}>
        Native reconstructions of `HermexTextField`, `HermexSecureField`, and `HermexCodeInput` — the
        three approved Default/Password/Code variants. Each Code specimen is exactly one native
        `TextInput` — number-pad keyboard, one-time-code content type, ASCII-digit-only filtering —
        layered under a decorative digit-box row hidden from accessibility, demonstrating lengths 4,
        6, and 8 across partial, complete, error, and disabled states without any auto-submit; helper
        and error text stay mutually exclusive per specimen, matching the native HermexTextInputShell
        contract. Production owns focus, keyboard, autocorrection, capitalization, and content type
        through these native controls, not through custom Hermex field chrome. TextEditor (long-form
        body text) and Search stay outside this family — see their own entries.
      </Text>
    </View>
  );
}

// ─── Bottom Sheet — HermexBottomSheet: TopNav header + unconstrained body slot (arbitrary content
// or List) + optional horizontal/vertical footer, all supplied to native `.sheet` ─────────────────
function BottomSheetSpecimen({
  label,
  body,
  footerAxis,
  footer,
}: {
  label: string;
  body: ReactNode;
  footerAxis: 'horizontal' | 'vertical';
  footer: ReactNode;
}) {
  return (
    <View style={preview.bottomSheetSpecimen}>
      <Text style={preview.label}>{label}</Text>
      <View style={preview.bottomSheetShell}>
        <TopNav
          title="Add Attachment"
          leadingPrimary={<Button variant="secondary" size="small" label="Cancel" onPress={() => {}} style={preview.topNavActionButton} />}
          trailingPrimary={<Button variant="secondary" size="small" label="Done" onPress={() => {}} style={preview.topNavActionButton} />}
        />
        <View style={preview.bottomSheetBody}>{body}</View>
        <View style={[preview.bottomSheetFooter, footerAxis === 'vertical' && preview.bottomSheetFooterVertical]}>
          {footer}
        </View>
      </View>
    </View>
  );
}

export function HermexBottomSheetFamilyGallery() {
  return (
    <View style={preview.stack}>
      <View style={preview.row}>
        <BottomSheetSpecimen
          label="Arbitrary content body + horizontal footer"
          body={
            <Text style={preview.bottomSheetBodyText}>
              Attach a file from Workspace, or drop one directly into this session. Files up to 25MB
              are supported.
            </Text>
          }
          footerAxis="horizontal"
          footer={
            <>
              <Button variant="secondary" label="Cancel" onPress={() => {}} style={preview.bottomSheetFooterButton} />
              <Button variant="primary" label="Attach" onPress={() => {}} style={preview.bottomSheetFooterButton} />
            </>
          }
        />

        <BottomSheetSpecimen
          label="List body + vertical footer"
          body={
            <List>
              <ListItem title="Workspace file" description="Browse the active workspace" onPress={() => {}} />
              <ListItem title="Photo Library" description="Choose an image or video" onPress={() => {}} />
              <ListItem title="Take Photo" description="Use the camera" onPress={() => {}} />
            </List>
          }
          footerAxis="vertical"
          footer={
            <>
              <Button variant="primary" label="Continue" onPress={() => {}} style={preview.bottomSheetFooterButtonFull} />
              <Button variant="tertiary" label="Cancel" onPress={() => {}} style={preview.bottomSheetFooterButtonFull} />
            </>
          }
        />
      </View>
      <Text style={preview.caption}>
        `HermexBottomSheet` is content supplied to native SwiftUI `.sheet` — the caller keeps owning
        `.sheet` itself: detents, the drag indicator, compact adaptation, interactive-dismiss policy,
        focus, validation, loading state, and dismissal. The scaffold only owns a `NavigationStack`,
        an inline title, this file's own TopNav composition (shown above using the same real TopNav
        reconstruction as the TopNav entry) at modal-appropriate placements, an unconstrained body
        slot — arbitrary content (left) or a native `List` (right, using the same real List/ListItem
        reconstruction as List/ListItem's own entry) — and an optional footer pinned with
        safe-area-aware layout, arranged horizontally (left) or vertically (right) by the caller.
        Native SwiftUI owns the sheet's presentation motion and Reduce Motion either way; this
        reconstruction shows the sheet surface inline for inspection rather than as a real
        overlay/backdrop, since production's own sheet always presents through `.sheet`, never a
        custom transition this component owns.
      </Text>
    </View>
  );
}

// ─── Dialog — HermexDialog: non-dismissible dimmed backdrop + centered card (standard close
// button, generic header/body, caller-oriented horizontal/vertical footer), mounted through the
// shared same-window overlay host rather than any native `.alert`/`.sheet` ──────────────────────
function DialogSpecimen({
  label,
  heading,
  body,
  footerAxis,
  footer,
}: {
  label: string;
  heading: string;
  body: string;
  footerAxis: 'horizontal' | 'vertical';
  footer: ReactNode;
}) {
  return (
    <View style={preview.dialogSpecimen}>
      <Text style={preview.label}>{label}</Text>
      <View style={preview.dialogBackdrop}>
        <View style={preview.dialogCard}>
          <View style={preview.dialogHeaderRow}>
            <Text style={preview.dialogHeading}>{heading}</Text>
            <View style={[preview.dialogCloseButton, preview.buttonGlassSurface]}>
              <Icon name="clear" size={12} color="#1c1c1e" />
            </View>
          </View>
          <Text style={preview.dialogBodyText}>{body}</Text>
          <View style={[preview.dialogFooter, footerAxis === 'vertical' && preview.dialogFooterVertical]}>
            {footer}
          </View>
        </View>
      </View>
    </View>
  );
}

export function DialogFamilyGallery() {
  return (
    <View style={preview.stack}>
      <View style={preview.row}>
        <DialogSpecimen
          label="Short confirmation — horizontal actions"
          heading="Delete this draft?"
          body="This removes the unsent draft from this device. It cannot be undone."
          footerAxis="horizontal"
          footer={
            <>
              <Button variant="secondary" label="Cancel" onPress={() => {}} style={preview.dialogFooterButton} />
              <Button variant="destructive" label="Delete" onPress={() => {}} style={preview.dialogFooterButton} />
            </>
          }
        />
        <DialogSpecimen
          label="Explanatory dialog — vertical actions"
          heading="Turn on notifications?"
          body="Hermex can notify you when a session needs your attention, even while the app is closed."
          footerAxis="vertical"
          footer={
            <>
              <Button variant="primary" label="Turn On" onPress={() => {}} style={preview.dialogFooterButtonFull} />
              <Button variant="tertiary" label="Not Now" onPress={() => {}} style={preview.dialogFooterButtonFull} />
            </>
          }
        />
      </View>
      <Text style={preview.caption}>
        `HermexDialog` mounts through the shared same-window overlay host, never `.alert`, `.sheet`,
        or another native presentation wrapper — shown here inline, over a static dimmed backdrop,
        for inspection rather than as a real floating overlay. The header row vertically centers the
        caller's own heading against a compact 24pt adaptive-glass close control (top right, always
        present) that keeps a 44pt minimum hit target even though its visual chrome is XS; the dimmed
        backdrop never dismisses the dialog. The horizontal footer (left) hugs the trailing edge with
        the caller's actions in their own authored order, lower emphasis first and higher emphasis
        last; the vertical footer (right) stacks top-to-bottom instead. Axis is always the caller's
        explicit choice, never inferred from action count or width.
      </Text>
    </View>
  );
}

// ─── Popover Menu — HermexPopoverMenu: a fully custom, always trigger-anchored floating menu
// mounted through the same shared same-window overlay host and HermexOverlayLifecycle as Dialog,
// never a native Menu/.contextMenu/.popover. Rows compose the real List/ListItem anatomy through
// List's new compactOverlay variant. ────────────────────────────────────────────────────────────
function PopoverMenuSpecimen({
  label,
  placement,
  triggerAlign,
  maxHeight,
  children,
}: {
  label: string;
  placement: 'below' | 'above';
  triggerAlign?: 'leading' | 'trailing';
  maxHeight?: number;
  children: ReactNode;
}) {
  const trigger = (
    <View style={[preview.popoverAnchorRow, triggerAlign === 'trailing' && preview.popoverAnchorRowTrailing]}>
      <View accessibilityLabel="Item actions" style={preview.popoverTrigger}>
        <Text style={preview.popoverTriggerText}>•••</Text>
      </View>
    </View>
  );
  const surface = (
    <View style={placement === 'above' ? preview.popoverSurfaceAbove : preview.popoverSurfaceBelow}>
      <List variant="compactOverlay" maxHeight={maxHeight} style={preview.popoverList}>
        {children}
      </List>
    </View>
  );
  return (
    <View style={preview.popoverSpecimen}>
      <Text style={preview.label}>{label}</Text>
      {/* A static reconstruction, not a real floating overlay — the source order below is what
          actually renders above/below the trigger, since a plain column has no z-index to fake it. */}
      {placement === 'above' ? (
        <>
          {surface}
          {trigger}
        </>
      ) : (
        <>
          {trigger}
          {surface}
        </>
      )}
    </View>
  );
}

// Own small entering/open/exiting phase, mirroring HermexPopoverMenu's real dismiss-then-act
// ordering (see approved-design.md's Popover Menu dismissal/action-ordering contract) rather than
// closing and firing an action in the same tick. Reuses the catalog's own existing overlay-exit/
// enter motion values (HERMES_MOTION_BUNDLES, already imported above) and the same useReduceMotion
// hook the Segmented Control preview below already defines — no invented duration, no new hook.
function PopoverMenuInteractiveDemo() {
  const reduceMotion = useReduceMotion();
  const [phase, setPhase] = useState<'closed' | 'open' | 'exiting'>('closed');
  const [lastAction, setLastAction] = useState<string | null>(null);
  const opacity = useRef(new Animated.Value(0)).current;
  const pendingActionRef = useRef<string | null>(null);
  const exitingRef = useRef(false);
  const mountedRef = useRef(true);

  useEffect(() => () => {
    mountedRef.current = false;
    opacity.stopAnimation();
  }, [opacity]);

  const isOpen = phase !== 'closed';

  const openMenu = () => {
    if (phase !== 'closed') return;
    setLastAction(null);
    setPhase('open');
    opacity.setValue(0);
    Animated.timing(opacity, {
      toValue: 1,
      duration: reduceMotion ? 0 : HERMES_MOTION_BUNDLES['motion.overlay.enter'].durationMs,
      useNativeDriver: false,
    }).start();
  };

  // The one shared exit path for every dismissal source (outside tap, Escape, or an enabled row):
  // begins the exit transition immediately, then commits the pending action — if any — only once
  // that transition actually finishes, exactly once. `exitingRef` blocks a second call (a repeat
  // tap, or Escape during the same exit) from replacing or duplicating the pending action; the
  // unmount cleanup above stops `opacity` outright, so a completion that would otherwise land after
  // this demo is gone never fires `setLastAction`/`setPhase` on a dead component.
  const beginExit = (actionAfterExit: string | null) => {
    if (phase !== 'open' || exitingRef.current) return;
    exitingRef.current = true;
    pendingActionRef.current = actionAfterExit;
    setPhase('exiting');
    Animated.timing(opacity, {
      toValue: 0,
      duration: reduceMotion ? 0 : HERMES_MOTION_BUNDLES['motion.overlay.exit'].durationMs,
      useNativeDriver: false,
    }).start(({ finished }) => {
      exitingRef.current = false;
      if (!finished || !mountedRef.current) return;
      setPhase('closed');
      const action = pendingActionRef.current;
      pendingActionRef.current = null;
      if (action != null) setLastAction(action);
    });
  };

  // Escape dismissal — web-only, same Platform.OS === 'web' / typeof document guard CatalogShell's
  // own document-level listeners already use, bound only while open and torn down with the effect
  // (closing, or a later placement change) so it never leaks past this demo's own lifetime.
  useEffect(() => {
    if (!isOpen) return;
    if (Platform.OS !== 'web' || typeof document === 'undefined') return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') beginExit(null);
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  return (
    <View style={preview.popoverSpecimen}>
      <Text style={preview.label}>Interactive — open, dismiss, act</Text>
      {isOpen && (
        // The outside-tap dismiss target — bounded to this demo's own card (see popoverBackdrop's
        // own doc comment above), not the full page, since this is an inline catalog specimen
        // rather than a real floating overlay. Rendered before the trigger/surface below so both
        // paint above it. `accessible={false}` keeps it out of the accessibility tree; it has no
        // visible content of its own to announce.
        <Pressable accessible={false} style={preview.popoverBackdrop} onPress={() => beginExit(null)} />
      )}
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Session actions"
        onPress={() => (isOpen ? beginExit(null) : openMenu())}
        style={preview.popoverTrigger}
      >
        <Text style={preview.popoverTriggerText}>•••</Text>
      </Pressable>
      {isOpen && (
        <Animated.View
          style={[preview.popoverSurfaceBelow, { opacity }]}
          pointerEvents={phase === 'open' ? 'auto' : 'none'}
        >
          <List variant="compactOverlay" style={preview.popoverList}>
            <ListItem title="Rename" onPress={() => beginExit('Rename')} />
            <ListItem title="Delete" onPress={() => beginExit('Delete')} />
          </List>
        </Animated.View>
      )}
      <Text style={preview.caption}>
        {lastAction == null
          ? 'Tap the trigger to open, tap a row to act, or tap outside/Escape to dismiss without acting.'
          : `Ran "${lastAction}" after exit completed — the same exactly-once action-after-exit dismissal HermexPopoverMenu guarantees.`}
      </Text>
    </View>
  );
}

export function PopoverMenuFamilyGallery() {
  return (
    <View style={preview.stack}>
      <View style={preview.row}>
        <PopoverMenuSpecimen label="Below the trigger (preferred placement)" placement="below">
          <ListItem title="Rename" onPress={() => {}} />
          <ListItem title="Duplicate" onPress={() => {}} />
          <ListItem title="Delete" onPress={() => {}} />
        </PopoverMenuSpecimen>

        <PopoverMenuSpecimen label="Above the trigger (flips when below doesn't fit)" placement="above">
          <ListItem title="Rename" onPress={() => {}} />
          <ListItem title="Duplicate" onPress={() => {}} />
        </PopoverMenuSpecimen>

        <PopoverMenuSpecimen label="Horizontal safe-area clamp (trigger near the trailing edge)" placement="below" triggerAlign="trailing">
          <ListItem title="Share" onPress={() => {}} />
          <ListItem title="Delete" disabled onPress={() => {}} />
        </PopoverMenuSpecimen>
      </View>

      <View style={preview.row}>
        <PopoverMenuSpecimen label="Standard, disabled, and destructive rows" placement="below">
          <ListItem title="Rename" onPress={() => {}} />
          <ListItem title="Archive" disabled onPress={() => {}} />
          <ListItem
            leading={<Icon name="circle-x" size={DS_ICON_SIZE.sm} color={HERMES_COLOR_RAMPS.Red[500]} />}
            title="Delete"
            onPress={() => {}}
          />
        </PopoverMenuSpecimen>

        <PopoverMenuSpecimen label="Constrained height — scrolls internally" placement="below" maxHeight={132}>
          <ListItem title="Assign to Alex" onPress={() => {}} />
          <ListItem title="Assign to Priya" onPress={() => {}} />
          <ListItem title="Assign to Sam" onPress={() => {}} />
          <ListItem title="Assign to Jordan" onPress={() => {}} />
          <ListItem title="Assign to Wei" onPress={() => {}} />
        </PopoverMenuSpecimen>

        <PopoverMenuInteractiveDemo />
      </View>

      <Text style={preview.caption}>
        `HermexPopoverMenu` mounts through the same shared same-window overlay host and
        `HermexOverlayLifecycle` as Dialog — never a native `Menu`, `.contextMenu`, or `.popover` —
        and is always trigger-anchored: it prefers below the trigger, flips above when below doesn't
        fit, and clamps horizontally inside the safe area. Shown here as static, inline specimens for
        inspection (the same convention as the Dialog and Bottom Sheet shells above), except the
        interactive example, which really opens, closes, and runs its action after exit completes.
        Rows compose the same real `List`/`ListItem` anatomy as the List / ListItem entry, through
        List's new transparent, separator-free `compactOverlay` variant; a destructive row's meaning
        is always textual, never color-only, and a disabled row stays visible but never activates.
        The surface applies one 16pt internal padding (`HermexPopoverMenuMetrics.contentPadding`) —
        rows compose `contentInset: .none` so that single 16pt boundary is never doubled by a second,
        stacked row-level inset. Tapping outside the menu or pressing Escape dismisses it without
        running an action.
      </Text>
    </View>
  );
}

interface SegmentedPreviewOption {
  value: string;
  label: string;
  count?: number;
}

function useReduceMotion(): boolean {
  const [reduceMotion, setReduceMotion] = useState(false);
  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
      if (mounted) setReduceMotion(enabled);
    });
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => {
      mounted = false;
      subscription.remove();
    };
  }, []);
  return reduceMotion;
}

function SegmentedPreviewOptionView({
  option,
  selected,
  fill,
  onPress,
}: {
  option: SegmentedPreviewOption;
  selected: boolean;
  fill?: boolean;
  onPress: () => void;
}) {
  const reduceMotion = useReduceMotion();
  const selectionProgress = useRef(new Animated.Value(selected ? 1 : 0)).current;

  useEffect(() => {
    if (reduceMotion) {
      selectionProgress.setValue(selected ? 1 : 0);
      return;
    }
    Animated.timing(selectionProgress, {
      toValue: selected ? 1 : 0,
      duration: 180,
      useNativeDriver: false,
    }).start();
  }, [reduceMotion, selected, selectionProgress]);

  const backgroundColor = selectionProgress.interpolate({
    inputRange: [0, 1],
    outputRange: ['rgba(255,255,255,0)', 'rgba(255,255,255,1)'],
  });

  return (
    <Pressable
      accessibilityRole="tab"
      accessibilityLabel={option.count == null ? option.label : `${option.label}, ${option.count}`}
      accessibilityState={{ selected }}
      onPress={onPress}
      style={({ pressed }) => [
        preview.segmentedTouchTarget,
        fill && preview.segmentedFixedOption,
        pressed && { opacity: 0.72 },
      ]}
    >
      <Animated.View style={[preview.segmentedPill, { backgroundColor }]}>
        <Text style={[preview.scrollingSegmentText, selected && preview.scrollingSegmentTextSelected]}>
          {option.label}{option.count == null ? '' : `  ${option.count}`}
        </Text>
      </Animated.View>
    </Pressable>
  );
}

function FixedSegmentedControlPreview() {
  const options: SegmentedPreviewOption[] = [
    { value: 'cost', label: 'Cost' },
    { value: 'tokens', label: 'Tokens' },
  ];
  const [value, setValue] = useState('tokens');

  return (
    <View style={preview.segmentedFixedTrackWrapper}>
      <View style={preview.segmentedFixedVisualTrack} />
      <View accessibilityRole="tablist" style={preview.segmentedFixedTrack}>
        {options.map((option) => (
          <SegmentedPreviewOptionView
            key={option.value}
            option={option}
            selected={option.value === value}
            fill
            onPress={() => setValue(option.value)}
          />
        ))}
      </View>
    </View>
  );
}

function ScrollingSegmentedControlPreview() {
  const options = [
    { value: 'backlog', label: 'Backlog', count: 8 },
    { value: 'ready', label: 'Ready', count: 3 },
    { value: 'doing', label: 'In progress', count: 2 },
    { value: 'review', label: 'Review', count: 1 },
    { value: 'done', label: 'Done', count: 12 },
  ];
  const [value, setValue] = useState('ready');
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ maxWidth: 402 }}>
      <View accessibilityRole="tablist" style={{ flexDirection: 'row', gap: 8, paddingHorizontal: 4 }}>
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <SegmentedPreviewOptionView
              key={option.value}
              option={option}
              selected={selected}
              onPress={() => setValue(option.value)}
            />
          );
        })}
      </View>
    </ScrollView>
  );
}

export function SegmentedControlGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Fixed"
        details={
          <Text style={preview.detailsText}>
            Used by Tasks, Usage window selection, and the Cost/Tokens selector. A distinct 40pt
            visual-track background sits behind the row (the 36pt selected pill plus one padding step
            above and below), while each option's interactive row keeps the full 44pt touch target that
            extends beyond it. At accessibility text sizes the equal-width segments grow vertically and
            labels may wrap to two centered lines rather than clipping or shrinking. Each option preserves
            native Button semantics while Hermex owns the track, selected pill, typography, and motion.
          </Text>
        }
      >
      <FixedSegmentedControlPreview />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Scrolling"
        details={
          <Text style={preview.detailsText}>
            Used by Kanban when the status set no longer fits an equal-width control. The selected pill
            transitions between options, uses a compact 36pt visual height inside a 44pt touch target,
            and switches instantly when Reduce Motion is enabled.
          </Text>
        }
      >
      <ScrollingSegmentedControlPreview />
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Shimmer (catalog-only animated reference, distinct from production Skeleton) ────────────────
export function ShimmerFamilyGallery() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Text lines</Text>
      <View style={{ gap: 6, width: 220 }}>
        <Shimmer variant="text" />
        <Shimmer variant="text" width="70%" />
      </View>
      <Text style={preview.label}>Circle / capsule / rectangle / rounded rectangle / card</Text>
      <View style={preview.row}>
        <Shimmer variant="circle" size={40} />
        <Shimmer variant="container" width={72} height={24} style={{ borderRadius: 999 }} />
        <Shimmer variant="container" width={72} height={24} style={{ borderRadius: 0 }} />
        <Shimmer variant="container" width={72} height={24} />
        <Shimmer variant="container" width={120} height={64} />
      </View>
      <Text style={preview.label}>Composed row (avatar + two text lines, one announcement)</Text>
      <SkeletonGroup style={{ flexDirection: 'row', gap: 10, alignItems: 'center', width: 240 }}>
        <Shimmer variant="circle" size={40} />
        <View style={{ flex: 1, gap: 6 }}>
          <Shimmer variant="text" />
          <Shimmer variant="text" width="60%" />
        </View>
      </SkeletonGroup>
      <Text style={preview.caption}>
        Production now composes the shared `SkeletonPlaceholder` primitive (Sessions row,
        Insights provider-limits card, chat transcript) — see the static gallery above for the
        production-faithful shapes. This animated Shimmer remains the catalog/reference-only
        counterpart, never a claimed production mapping.
      </Text>
    </View>
  );
}

// ─── List / ListItem ──────────────────────────────────────────────────────────
export function ListItemFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Standard rows"
        fill
        details={
          <Text style={preview.detailsText}>
            Every documented slot rendered by this generic RN component, including the title-adjacent
            accessory, an accessibility-label override on the first row, and the loading row above (one
            "Loading" announcement via SkeletonGroup, not one per Shimmer block). The first row's trailing
            "Archive" Button stays independently focusable and tappable even though the row itself is also
            pressable — the trailing accessory sits outside the row's own selecting Pressable, so an
            accessible Pressable never swallows it.
          </Text>
        }
      >
      <List>
        <ListItem
          leading={<Avatar initials="JS" size={32} />}
          title="Login"
          titleAccessory={<Badge variant="warning" label="WIP" />}
          description="feature/auth"
          metadata="2 files"
          trailingText="2m"
          onPress={() => {}}
          trailing={<Button label="Archive" size="extraSmall" variant="tertiary" onPress={() => {}} />}
          accessibilityLabel="Login branch, feature/auth, work in progress"
        />
        <ListItem
          leading={<Avatar iconName="menu" size={32} />}
          title="Nightly"
          trailingText="Queued"
          trailingSubtext="ETA 4m"
        />
        <ListItem title="Archived" disabled trailing={<Text style={preview.caption}>›</Text>} />
        <ListItem leading={<Avatar initials="?" size={32} />} title="Loading…" loading />
      </List>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Picker configuration"
        fill
        details={
          <Text style={preview.detailsText}>
            A picker is not a separate family — it is ListItem used with the real `selected`
            accessibility state and a trailing checkmark, a distinct `commitPending` state once a choice
            is submitted (real content stays visible, unlike the `loading` skeleton above it), and the
            existing loading/disabled states. Model, profile, task-configuration, and skill pickers all
            target this configuration rather than a standalone Picker Row component. The generic
            catalog ListItem's own `selected` prop carries the accessibility state but does not render
            native pill chrome, so the selected row below is an explicit source-faithful reconstruction:
            a Color.primary pill with inverse title/checkmark foreground. Its checkmark is generated by
            selected state, not supplied through the caller-owned trailing accessory slot.
          </Text>
        }
      >
      <List>
        <ListItemSelectedRowDemo label="GPT-5.1" />
        <ListItem title="Claude Opus 5" onPress={() => {}} />
        <ListItem title="Applying selection…" commitPending />
        <ListItem title="Fetching models…" loading />
        <ListItem title="Unavailable model" disabled />
      </List>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="SessionListItem"
        fill
        details={
          <Text style={preview.detailsText}>
            This SessionListItem composition is a new, foundation-only demonstration with no production
            call site — it composes ListItem's leading/title/description/metadata/trailing slots with
            session-specific anatomy: a streaming indicator dot (titleAccessory), an attention-status
            metadata line, and responsive reflow at narrow widths. Production's live session row is
            SessionRowView, which keeps its title plain and shows the match as a separate highlighted
            excerpt line beneath the title (`SessionSearchExcerpt.highlighted`). This generic ListItem
            preview does not model that dedicated excerpt line; its titleAccessory badge demonstrates
            only the separate title-adjacent slot, not search highlighting. Native Button wrapping,
            swipe actions, context menus,
            selection background, transitions, and the single screen-level horizontal inset are
            caller-owned in production by SessionInteractiveRow, which wraps SessionRowView (not this
            SessionListItem) in SessionListComponents.swift.
          </Text>
        }
      >
      <List>
        <ListItem
          leading={<Avatar initials="HM" size={32} backgroundColor="#3478F6" />}
          title="Ship the release notes"
          titleAccessory={<View style={preview.streamDot} accessibilityLabel="Streaming" />}
          description="Ran `npm test` — 2 tool calls"
          metadata={<Text style={preview.attentionText}>Needs your input</Text>}
          trailingText="2m"
        />
        <ListItem
          leading={<Avatar initials="AB" size={32} backgroundColor="#8E8E93" />}
          title="Investigate flaky build failure"
          titleAccessory={<Text style={{ fontSize: 11, fontWeight: '700', color: '#3478F6' }}>build</Text>}
          description="Archived · Read-only"
          trailingText="1d"
        />
      </List>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="compactOverlay style"
        fill
        details={
          <Text style={preview.detailsText}>
            `variant="compactOverlay"` renders the same real `List`/`ListItem` anatomy with no separators
            on a transparent, bounded-height, internally-scrolling container — the exact style Popover
            Menu composes for its own floating action rows (see the Popover Menu entry). `standard`
            stays the unchanged default shown in every specimen above.
          </Text>
        }
      >
      <List variant="compactOverlay" maxHeight={140} style={preview.compactOverlayDemoList}>
        <ListItem title="Rename" onPress={() => {}} />
        <ListItem title="Duplicate" onPress={() => {}} />
        <ListItem title="Delete" onPress={() => {}} />
      </List>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Pressed feedback · Content inset"
        details={
          <Text style={preview.detailsText}>
            Both rows below render at rest, so the `contentInset: .standard` (left, HermesSpacing.s12
            horizontal) versus `contentInset: .none` (right, no horizontal inset) difference — a
            resting-state geometry fact, not an interaction — is visible without pressing anything. The
            third row is statically pressed: every tappable row's pressed surface is a rounded rectangle
            at `ListItemMetrics.cornerRadius` — never the plain full-bleed rectangle fill this generic
            template's own `pressed` style still uses — with no spatial scale, transitioning
            color/opacity over `HermesMotion.Bundle.stateChange` (150ms). `.none` is the composition
            Popover Menu uses so its own 16pt shell inset is never doubled (see the Popover Menu entry).
            Disabled and pending rows show no pressed feedback at all.
          </Text>
        }
      >
      <View style={preview.row}>
        <ListItem leading={<Avatar initials="A" size={32} />} title="Standard inset" trailing={<Text style={preview.caption}>›</Text>} onPress={() => {}} />
        <ListItem leading={<Avatar initials="B" size={32} />} title="None inset" trailing={<Text style={preview.caption}>›</Text>} onPress={() => {}} style={preview.listItemContentInsetNone} />
        <ListItemPressedRowDemo label="Statically pressed" inset="standard" forcePressed />
      </View>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

function ListItemSelectedRowDemo({ label }: { label: string }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ selected: true }}
      onPress={() => {}}
      style={preview.listItemSelectedPill}
    >
      <Text style={[preview.listItemSelectedForeground, preview.listItemSelectedTitle]}>{label}</Text>
      <Text style={[preview.listItemSelectedForeground, { fontWeight: '600' }]} accessibilityElementsHidden>✓</Text>
    </Pressable>
  );
}

// DSR3-07: a hand-built recon of ListItem's real rounded pressed `ButtonStyle` — the generic
// template's own ListItem has no such style (a plain rectangle `pressed` fill, no rounding, no
// content-inset seam), so this demonstrates the real Hermex treatment directly rather than a
// bolted-on prop this shared component doesn't have.
function ListItemPressedRowDemo({ label, inset, forcePressed = false }: { label: string; inset: 'standard' | 'none'; forcePressed?: boolean }) {
  const [pressed, setPressed] = useState(forcePressed);
  return (
    <Pressable
      onPressIn={() => setPressed(true)}
      onPressOut={() => setPressed(forcePressed)}
      accessibilityRole="button"
      accessibilityLabel={label}
      style={[
        preview.listItemPressedRow,
        inset === 'none' && preview.listItemPressedRowInsetNone,
        pressed && preview.listItemPressedRowActive,
      ]}
    >
      <Text style={preview.label}>{label}</Text>
    </Pressable>
  );
}

// ─── Accordion List ──────────────────────────────────────────────────────────
interface AccordionSessionRow {
  id: string;
  title: string;
  description?: string;
}

interface AccordionProjectRow {
  id: string;
  title: string;
  sessions: AccordionSessionRow[];
}

const ACCORDION_PROJECTS: AccordionProjectRow[] = [
  {
    id: 'hermex',
    title: 'Hermex',
    sessions: [
      { id: 'ds', title: 'Design system foundation', description: 'Active · just now' },
      { id: 'sessions', title: 'Session list redesign', description: 'Yesterday' },
      { id: 'push', title: 'Push recovery audit', description: 'Sep 24' },
    ],
  },
  {
    id: 'website',
    title: 'Website',
    sessions: [
      { id: 'landing', title: 'Landing page review', description: 'Sep 23' },
    ],
  },
];

function AccordionListCardMultipleDemo() {
  const [expandedIds, setExpandedIds] = useState<string[]>(['hermex']);
  return (
    <AccordionList
      items={ACCORDION_PROJECTS}
      appearance="card"
      separatorStyle="betweenRows"
      mode="multiple"
      expandedIds={expandedIds}
      onExpandedIdsChange={setExpandedIds}
      getHeader={(project) => ({
        title: project.title,
        description: `${project.sessions.length} sessions`,
        leading: <Avatar iconName="briefcase" size="small" />,
      })}
      getBodyItems={(project) => project.sessions}
      renderBodyItem={(_project, session) => (
        <ListItem key={session.id} title={session.title} description={session.description} />
      )}
    />
  );
}

function AccordionListCardlessSingleDemo() {
  const [expandedIds, setExpandedIds] = useState<string[]>([]);
  return (
    <AccordionList
      items={ACCORDION_PROJECTS}
      appearance="cardless"
      separatorStyle="betweenRows"
      mode="single"
      expandedIds={expandedIds}
      onExpandedIdsChange={setExpandedIds}
      getHeader={(project) => ({
        title: project.title,
        description: `${project.sessions.length} sessions`,
        leading: <Avatar iconName="briefcase" size="small" />,
      })}
      getBodyItems={(project) => project.sessions}
      renderBodyItem={(_project, session) => (
        <ListItem key={session.id} title={session.title} description={session.description} />
      )}
    />
  );
}

// DSR3-08: no-leading header mode — `leading: null` (no avatar/icon slot at all). Header title starts
// at ListItem's own standard content column, and body rows/dividers align to that same column
// instead of the avatar-derived indentation the leading-present demos above use.
function AccordionListNoLeadingDemo() {
  const [expandedIds, setExpandedIds] = useState<string[]>(['hermex']);
  return (
    <AccordionList
      items={ACCORDION_PROJECTS}
      appearance="card"
      separatorStyle="betweenRows"
      mode="multiple"
      expandedIds={expandedIds}
      onExpandedIdsChange={setExpandedIds}
      getHeader={(project) => ({ title: project.title, description: `${project.sessions.length} sessions`, leading: null })}
      getBodyItems={(project) => project.sessions}
      renderBodyItem={(_project, session) => (
        <ListItem key={session.id} title={session.title} description={session.description} />
      )}
    />
  );
}

function AccordionSeparatorDemo({
  separatorStyle,
  label,
  details,
}: {
  separatorStyle: 'none' | 'betweenRows' | 'topAndBottom' | 'all';
  label: string;
  details?: ReactNode;
}) {
  return (
    <PreviewSpecimen name={`Separator style · ${label}`} details={details} fill>
      <AccordionList
        items={ACCORDION_PROJECTS.slice(0, 1)}
        appearance="cardless"
        separatorStyle={separatorStyle}
        mode="multiple"
        initialExpandedIds={['hermex']}
        getHeader={(project) => ({ title: project.title, leading: <Avatar iconName="briefcase" size="small" /> })}
        getBodyItems={(project) => project.sessions}
        renderBodyItem={(_project, session) => <ListItem key={session.id} title={session.title} />}
      />
    </PreviewSpecimen>
  );
}

export function AccordionListFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Card · Multiple"
        fill
        details={
          <Text style={preview.detailsText}>
            Interactive — tap a header to expand or collapse it. Header titles use label typography
            (semibold); session/body titles stay on the regular body
            weight, so the project header reads visibly stronger than the sessions it discloses. The card
            composes the shared Card component (outlined surface) for its 16pt horizontal content
            padding; the chevron renders at the 20pt (medium) icon-size step; and body expansion/
            collapse visibly animates (respecting Reduce Motion) instead of snapping open or shut.
          </Text>
        }
      >
      <AccordionListCardMultipleDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Cardless · Single"
        fill
        details={
          <Text style={preview.detailsText}>
            Interactive — opening one header closes the other. Collapsed cardless project headers share
            one divider between adjacent rows; expanding a
            second header collapses the first back to zero-or-one open, and tapping the open header
            again collapses it to none. Cardless adds no Accordion-level horizontal outer padding — only
            ListItem's own row insets apply. The divider directly under an open header spans the full
            available width; the divider between two session rows begins at their own text column
            (avatar width + header/body gap + ListItem's own horizontal inset), not the row's outer edge.
          </Text>
        }
      >
      <AccordionListCardlessSingleDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Card · Multiple · No leading"
        fill
        details={
          <Text style={preview.detailsText}>
            Interactive — tap a header to expand or collapse it. `leading: null` (no leading initializer)
            removes the avatar-width-derived indentation
            entirely: the header title starts at ListItem's own standard content column, body rows keep
            their own standard inset, and the divider between two body rows aligns to that same column
            instead of the leading-present demos' avatar-derived one above.
          </Text>
        }
      >
      <AccordionListNoLeadingDemo />
      </PreviewSpecimen>
      <AccordionSeparatorDemo separatorStyle="none" label="none" />
      <AccordionSeparatorDemo separatorStyle="betweenRows" label="betweenRows" />
      <AccordionSeparatorDemo
        separatorStyle="topAndBottom"
        label="topAndBottom"
        details={
          <Text style={preview.detailsText}>
            A top line renders above the header; collapsed cardless rows share one project boundary.
          </Text>
        }
      />
      <AccordionSeparatorDemo separatorStyle="all" label="all" />
      <PreviewSpecimen
        name="Disabled header"
        fill
        details={<Text style={preview.detailsText}>A disabled header never toggles, regardless of tap or accessibility action.</Text>}
      >
      <AccordionList
        items={[{ id: 'archived', title: 'Archived project', sessions: [] as AccordionSessionRow[] }]}
        appearance="card"
        separatorStyle="betweenRows"
        mode="multiple"
        initialExpandedIds={[]}
        getHeader={(project) => ({
          title: project.title,
          description: 'Read-only',
          leading: <Avatar iconName="circle-slash" size="small" />,
          disabled: true,
        })}
        getBodyItems={(project) => project.sessions}
        renderBodyItem={(_project, session) => <ListItem key={session.id} title={session.title} />}
      />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Loading · Empty · Show all"
        fill
        details={
          <Text style={preview.detailsText}>
            The component renders every body row a caller supplies, including loading, empty, and
            “Show all” rows — it never caps row count or invents its own product messaging. Body rows
            also align to the header title column, matching the header's leading avatar width plus the
            shared row gap.
          </Text>
        }
      >
      <AccordionList
        items={[
          { id: 'loading', title: 'Loading project', sessions: [{ id: 'loading-row', title: 'Loading sessions…' }] },
          { id: 'empty', title: 'Empty project', sessions: [{ id: 'empty-row', title: 'No sessions' }] },
          {
            id: 'show-all',
            title: 'Large project',
            sessions: [
              { id: 'recent-1', title: 'Investigate flaky build failure', description: '2h' },
              { id: 'show-all-row', title: 'Show all sessions' },
            ],
          },
        ]}
        appearance="card"
        separatorStyle="betweenRows"
        mode="multiple"
        initialExpandedIds={['loading', 'empty', 'show-all']}
        getHeader={(project) => ({ title: project.title, leading: <Avatar iconName="briefcase" size="small" /> })}
        getBodyItems={(project) => project.sessions}
        renderBodyItem={(_project, session) => <ListItem key={session.id} title={session.title} description={session.description} />}
      />
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Checkbox ────────────────────────────────────────────────────────────────
/**
 * Reuses the real generic catalog Checkbox directly — no Hermex-specific duplicate. Covers checked,
 * unchecked, and disabled as static instances; a live interactive instance (tap to toggle, Tab to
 * focus); and the row-owned indicator configuration a multi-select list uses — `onChange` omitted so
 * the box renders as a non-interactive, accessibility-hidden visual and the owning ListItem's own
 * Pressable and `selected` state remain the only interactive/accessible control, never a checkbox
 * nested inside another control.
 */
function CheckboxInteractiveDemo() {
  const [checked, setChecked] = useState(false);
  return <Checkbox checked={checked} onChange={setChecked} label="Remember this trip" colors={HERMEX_SELECTION_CONTROL_COLORS} />;
}

function CheckboxRowOwnedDemo() {
  const [selectedIds, setSelectedIds] = useState<Record<string, boolean>>({ report: true, notes: false });
  const files: { key: string; title: string }[] = [
    { key: 'report', title: 'quarterly-report.pdf' },
    { key: 'notes', title: 'notes.md' },
  ];
  return (
    <List>
      {files.map((file) => (
        <ListItem
          key={file.key}
          leading={<Checkbox checked={!!selectedIds[file.key]} colors={HERMEX_SELECTION_CONTROL_COLORS} />}
          title={file.title}
          selected={!!selectedIds[file.key]}
          onPress={() => setSelectedIds((prev) => ({ ...prev, [file.key]: !prev[file.key] }))}
        />
      ))}
    </List>
  );
}

export function CheckboxFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen name="Unchecked · Checked">
      <View style={preview.row}>
        <Checkbox checked={false} onChange={() => {}} label="Unchecked" colors={HERMEX_SELECTION_CONTROL_COLORS} />
        <Checkbox checked={true} onChange={() => {}} label="Checked" colors={HERMEX_SELECTION_CONTROL_COLORS} />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen name="Disabled">
      <View style={preview.row}>
        <Checkbox checked={false} onChange={() => {}} disabled label="Disabled, unchecked" colors={HERMEX_SELECTION_CONTROL_COLORS} />
        <Checkbox checked={true} onChange={() => {}} disabled label="Disabled, checked" colors={HERMEX_SELECTION_CONTROL_COLORS} />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Interactive"
        details={
          <Text style={preview.detailsText}>
            Tap to toggle; Tab to focus. Tab reaches the box and shows a focus ring around it; a tap or
            Space/Enter toggles it — the
            real, live generic catalog Checkbox this entry documents directly, not a static picture.
          </Text>
        }
      >
      <CheckboxInteractiveDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Adaptive selected fill"
        details={
          <Text style={preview.detailsText}>
            Production HermexCheckbox fills and borders the checked box with the adaptive semantic
            Neutral mapping — deep Neutral.s950 in light appearance and near-white Neutral.s50 in dark — not
            a fixed accent color; the checkmark uses the inverse Neutral pair so it remains legible
            against either. Every Checkbox specimen above now passes that same light-appearance mapping
            via the shared colors prop, matching native instead of the reusable template's own unrelated
            blue default.
          </Text>
        }
      >
      <AdaptiveSelectedFillSwatch shape="square" />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Row-owned indicator (multi-select list)"
        fill
        details={
          <Text style={preview.detailsText}>
            Each row's own Pressable owns the tap and exposes `accessibilityState.selected`; the leading
            Checkbox omits `onChange`, so it renders the identical box/checkmark visual as a
            non-interactive, accessibility-hidden indicator rather than a second control nested inside the
            row — the same one-control-per-row rule ListItem's picker checkmark (see List / ListItem)
            already follows, applied here to a multi-select rather than a single-select choice.
          </Text>
        }
      >
      <CheckboxRowOwnedDemo />
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Attachment ────────────────────────────────────────────────────────────────
export function AttachmentTileGallery() {
  const fileIconPanelSize = { width: HERMES_ATTACHMENT_SIZE.fileIconPanelWidth, height: HERMES_ATTACHMENT_SIZE.fileIconPanelHeight };
  const accessibilityFileIconPanelSize = {
    width: HERMES_ATTACHMENT_SIZE.fileIconPanelWidthAccessibility,
    height: HERMES_ATTACHMENT_SIZE.fileIconPanelHeightAccessibility,
  };
  const gridCellSize = { width: HERMES_ATTACHMENT_SIZE.messageGridCell, height: HERMES_ATTACHMENT_SIZE.messageGridCell };
  const messageFileNameWidth = { maxWidth: HERMES_ATTACHMENT_SIZE.messageGridCell - HERMES_ATTACHMENT_SIZE.messageFileTextInset };

  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Message attachment · Composer attachment"
        fill
        details={
          <Text style={preview.detailsText}>
            Both normal (non-mini) tiles compose Compact Card for their outer surface. The 118×118pt
            message tile mirrors GridAttachmentCell's centered glyph, filename, and extension stack; its
            filename width is messageGridCell minus messageFileTextInset (18pt). The composer tile uses
            the fileIconPanelWidth × fileIconPanelHeight (58×68pt) icon panel and is fixed to
            composerFileTileWidth × composerFileTileMinHeight (222×92pt; 280×112pt under accessibility
            text sizes), with composerFileTextWidth (128pt; 160pt accessibility). It adds a real remove
            Button overlapping the corner by removeOverlap (6pt); the sent message tile does not. Each
            mapped file type renders its own distinct glyph and tint — a spreadsheet (Green 500) example
            sits alongside the PDF (Red 500) and text-like (Blue 500) tiles here. This icon set has no
            tablecells/doc.text/archivebox SF Symbols, so `waypoints`/`menu`/`briefcase` stand in for
            them here only to keep every mapped type visually distinct — AttachmentFileType's own real
            SF Symbol mapping is documented in the prop table above.
          </Text>
        }
      >
      <View style={preview.row}>
        <Card density="compact" style={[preview.messageFileTile, gridCellSize]}>
          <Icon name="paperclip" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Red[500]} />
          <Text style={[preview.tileName, messageFileNameWidth]} numberOfLines={2}>quarterly-report.pdf</Text>
          <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Red[500] }]}>PDF</Text>
        </Card>
        <Card density="compact" style={[preview.messageFileTile, gridCellSize]}>
          <Icon name="waypoints" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Green[500]} />
          <Text style={[preview.tileName, messageFileNameWidth]} numberOfLines={2}>Q3-actuals.xlsx</Text>
          <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Green[500] }]}>XLSX</Text>
        </Card>
        <View>
          <Card
            density="compact"
            style={[preview.composerFileTile, { width: HERMES_ATTACHMENT_SIZE.composerFileTileWidth, minHeight: HERMES_ATTACHMENT_SIZE.composerFileTileMinHeight }]}
          >
            <View style={[preview.fileIconPanel, fileIconPanelSize, { backgroundColor: HERMES_COLOR_RAMPS.Blue[100] }]}>
              <Icon name="menu" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Blue[500]} />
              <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Blue[500] }]}>MD</Text>
            </View>
            <View style={[preview.composerTileText, { width: HERMES_ATTACHMENT_SIZE.composerFileTextWidth }]}>
              <Text style={preview.composerTileName} numberOfLines={2}>notes.md</Text>
              <Text style={preview.composerTileDetail}>4 KB</Text>
            </View>
          </Card>
          {/* "white" (opaque DS_SEMANTIC.surface.white/main/muted), not "secondary" (alpha-derived
              surface.recessed) — mirrors production's opaque Color(.systemBackground) fill so the ×
              stays legible over an arbitrary thumbnail beneath it, and never an alpha/opacity-derived
              close-control color. */}
          <Button
            variant="white"
            size="extraSmall"
            showIcon
            showLabel={false}
            iconName="clear"
            accessibilityLabel="Remove notes.md"
            onPress={() => {}}
            style={[
              preview.attachmentRemove,
              { width: HERMES_ATTACHMENT_SIZE.removeControl, height: HERMES_ATTACHMENT_SIZE.removeControl, top: -HERMES_ATTACHMENT_SIZE.removeOverlap, right: -HERMES_ATTACHMENT_SIZE.removeOverlap },
            ]}
          />
        </View>
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Accessibility composer geometry"
        fill
        details={
          <Text style={preview.detailsText}>
            Accessibility text sizes expand the icon panel to
            fileIconPanelWidthAccessibility × fileIconPanelHeightAccessibility (76×84pt), preserving the
            full extension label instead of truncating it inside the fixed default panel.
          </Text>
        }
      >
      <View style={preview.row}>
        <Card
          density="compact"
          style={[
            preview.composerFileTile,
            {
              width: HERMES_ATTACHMENT_SIZE.composerFileTileWidthAccessibility,
              minHeight: HERMES_ATTACHMENT_SIZE.composerFileTileMinHeightAccessibility,
            },
          ]}
        >
          <View style={[preview.fileIconPanel, accessibilityFileIconPanelSize, { backgroundColor: HERMES_COLOR_RAMPS.Red[100] }]}>
            <Icon name="paperclip" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Red[500]} />
            <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Red[500] }]}>PDF</Text>
          </View>
          <View style={[preview.composerTileText, { width: HERMES_ATTACHMENT_SIZE.composerFileTextWidthAccessibility }]}>
            <Text style={preview.composerTileName} numberOfLines={2}>quarterly-report.pdf</Text>
            <Text style={preview.composerTileDetail}>2.1 MB</Text>
          </View>
        </Card>
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Compact attachment preview · Outside Card"
        details={
          <Text style={preview.detailsText}>
            The mini-preview is sized directly from HermesAttachmentSize.compactPreview (30×30pt) and
            stays a plain, tappable thumbnail — deliberately not Card/Compact Card anatomy, since neither
            Card's default 16pt padding nor Compact Card's own padding fits that geometry.
          </Text>
        }
      >
      <View style={preview.row}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Preview diagram.png"
          onPress={() => {}}
          style={[
            preview.miniPreviewThumb,
            { width: HERMES_ATTACHMENT_SIZE.compactPreview, height: HERMES_ATTACHMENT_SIZE.compactPreview, backgroundColor: HERMES_COLOR_RAMPS.Blue[100] },
          ]}
        >
          <Icon name="paperclip" size={DS_ICON_SIZE.sm} color={HERMES_COLOR_RAMPS.Blue[500]} />
        </Pressable>
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="File fallback · Loading · Failure"
        fill
        details={
          <View style={{ gap: 8 }}>
            <Text style={preview.detailsText}>
              File fallback (no extension match, Neutral 500), an in-flight loading state — a single
              full-box Shimmer placeholder sized to the same messageGridCell box it stands in for, not a
              hand-built tile — and an upload-failure state (archive, Orange 500) with a real Icon badge.
              Retry is caller-owned recovery UI composed around the tile in production
              (MessageBubbleView/ChatComposerAttachmentStripView), not part of this foundation family, so
              it is not depicted here. The loading Shimmer stands in for indefinite loading only — not a
              measurable upload percentage, which the production tile shows separately. AttachmentFileType
              still owns the icon/tint/label mapping; each surface keeps its own tile layout, upload/retry,
              and remove/preview interaction.
            </Text>
            <Text style={preview.detailsText}>
              Each tile is one combined accessibility element naming the attachment and its type/detail/
              state (e.g. "diagram.png, PNG, upload failed").
            </Text>
          </View>
        }
      >
      <View style={preview.row}>
        <View style={[preview.tileBox, gridCellSize]}>
          <Icon name="paperclip" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Neutral[500]} />
          <Text style={[preview.tileName, { color: HERMES_COLOR_RAMPS.Neutral[500] }]} numberOfLines={2}>README</Text>
          <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Neutral[500] }]}>FILE</Text>
        </View>
        <Shimmer variant="container" width={HERMES_ATTACHMENT_SIZE.messageGridCell} height={HERMES_ATTACHMENT_SIZE.messageGridCell} style={preview.tileBox} />
        <View>
          <View style={[preview.tileBox, gridCellSize]}>
            <Icon name="briefcase" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Orange[500]} />
            <Text style={[preview.tileName, { color: HERMES_COLOR_RAMPS.Orange[500] }]} numberOfLines={2}>backup.zip</Text>
            <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Orange[500] }]}>ZIP</Text>
          </View>
          <View style={preview.attachmentFailureBadge}>
            <Icon name="alert-circle" size={DS_ICON_SIZE.sm} color={HERMES_COLOR_RAMPS.Red[500]} />
          </View>
        </View>
      </View>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Banner ───────────────────────────────────────────────────────────────────
export function BannerFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen name="Information · Warning · Error · Success" fill>
      <View style={{ gap: 8 }}>
        <Banner variant="info" title="Information" description="An in-flow status update." />
        <Banner variant="warning" title="Warning" description="Something needs attention soon." />
        <Banner variant="negative" title="Error" description="Something failed." />
        <Banner variant="positive" title="Success" description="The action completed." />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Offline"
        fill
        details={
          <Text style={preview.detailsText}>
            One shared Offline Banner replaces the two near-duplicate offline-cache notices (Sessions
            list and Chat transcript), which previously differed in copy (hyphen vs. em dash), padding,
            and whether their icon was hidden from VoiceOver. HermexBanner.offlineCache() presents an
            orange, full-width, square-cornered, borderless band with a wifi-slash glyph — the warning
            variant's tint and triangle-alert glyph are this icon set's closest stand-ins for that
            orange wifi-slash SF Symbol, and borderRadius: 0 reconstructs the square-cornered edge.
          </Text>
        }
      >
      <Banner variant="warning" icon="triangle-alert" title="Offline — viewing cached version" style={preview.bannerFullWidth} />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Optional action · Inset vs. full-width"
        fill
        details={
          <Text style={preview.detailsText}>
            A decorative status icon is hidden from VoiceOver by default (the surrounding row/title
            already announces the same fact); pass a meaningful icon override only when the glyph itself
            carries information the title text doesn't.
          </Text>
        }
      >
      <View style={{ gap: 8 }}>
        <Banner
          variant="warning"
          title="Update required"
          description="A new version fixes a known issue."
          action={{ label: 'Update', onPress: () => {} }}
          style={preview.bannerFullWidth}
        />
        <View style={{ paddingHorizontal: 16 }}>
          <Banner variant="info" title="Inset presentation" description="Padded inside its container, not edge-to-edge." />
        </View>
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Description only"
        fill
        details={
          <Text style={preview.detailsText}>
            Title and description are independently caller-optional on the native HermexBanner, not an
            interactive show/hide toggle. This foundation-only specimen demonstrates a description-only,
            inset error composition by omitting the title prop entirely, never by passing an empty title;
            it is not a production Chat composer adoption claim.
          </Text>
        }
      >
      <View style={{ paddingHorizontal: 16 }}>
        <Banner
          variant="negative"
          description="The Hermes server hit an internal error. Check the server logs, then try again."
        />
      </View>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── TopNav ─────────────────────────────────────────────────────────────────────
// Icon-first, accessibly-labeled, and composed with the same Adaptive Glass surface as Buttons'
// Glass entry — a style composition on top of the existing variant, not a bespoke tint of its own.
function iconSlotButton(iconName: IconName, label: string) {
  return <Button variant="secondary" size="small" showIcon showLabel={false} iconName={iconName} accessibilityLabel={label} onPress={() => {}} style={[preview.topNavActionButton, preview.buttonGlassSurface]} />;
}

export function TopNavFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Standard navigation"
        details={<Text style={preview.detailsText}>Uses leadingPrimary, a centered title, and trailingPrimary.</Text>}
        fill
      >
      <View style={preview.topNavShell}>
        <TopNav
          title="Sessions"
          leadingPrimary={iconSlotButton('chevron-left', 'Back')}
          trailingPrimary={iconSlotButton('search', 'Search')}
        />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Modal / editor"
        details={<Text style={preview.detailsText}>Uses a labeled leadingPrimary action and trailingPrimary action.</Text>}
        fill
      >
      <View style={preview.topNavShell}>
        <TopNav
          title="New Task"
          leadingPrimary={<Button variant="secondary" size="small" label="Cancel" onPress={() => {}} style={preview.topNavActionButton} />}
          trailingPrimary={<Button variant="secondary" size="small" label="Save" onPress={() => {}} style={preview.topNavActionButton} />}
        />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Populated two-leading / two-trailing"
        fill
        details={
          <Text style={preview.detailsText}>
            Reading order stays semantic on both sides — the primary action sits closest to the screen
            edge, the secondary action closest to the title — so slot order never has to be inferred from
            layout alone. Both sides always reserve the same two-slot minimum width, whether zero, one, or
            two of their slots are populated, so the centered title/`center` content never shifts.
          </Text>
        }
      >
      <View style={preview.topNavShell}>
        <TopNav
          title="quarterly-report.pdf"
          leadingPrimary={iconSlotButton('chevron-left', 'Back')}
          leadingSecondary={iconSlotButton('pencil', 'Rename')}
          trailingSecondary={iconSlotButton('paperclip', 'Attachments')}
          trailingPrimary={iconSlotButton('menu', 'More options')}
        />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Long title truncation"
        fill
        details={
          <Text style={preview.detailsText}>
            The long title truncates rather than overlapping the actions on either side. Production
            renders this anatomy through native `ToolbarContent`; a simple screen with no custom
            leading/trailing actions may just set a native navigation title instead of composing TopNav
            at all. Bottom and keyboard toolbars are a separate concern, out of scope for TopNav.
            Every slot's action keeps its own accessibilityLabel and a ≥44×44pt hit target regardless of
            how many of the four optional slots are populated; the centered title/`center` content always
            truncates (`numberOfLines={1}`) rather than overlapping the reserved slot areas.
          </Text>
        }
      >
      <View style={preview.topNavShell}>
        <TopNav
          title="A very long conversation title that would otherwise collide with the actions on either side"
          leadingPrimary={iconSlotButton('chevron-left', 'Back')}
          trailingPrimary={iconSlotButton('search', 'Search')}
        />
      </View>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Disclosure / Log Row ──────────────────────────────────────────────────────
/**
 * The row itself IS the Button-like disclosure — a real Pressable exposing
 * accessibilityState.expanded and toggling on its own onPress, not a separate underlined text
 * control below a non-interactive row. Expand/collapse is an immediate show/hide in this browser
 * reference; production adds the Reduce-Motion-aware transition. A long press on the expanded body
 * reconstructs the real row's copy-to-clipboard behavior. The shared downward chevron rotates 180°
 * when expanded, while accessibilityState.expanded carries the same state semantically.
 */
function DisclosureChevron({ expanded }: { expanded: boolean }) {
  return (
    <View style={{ transform: [{ rotate: expanded ? '180deg' : '0deg' }] }}>
      <Icon name="chevron-down" size={DS_ICON_SIZE.xxs} color="#8a8a8a" />
    </View>
  );
}

export function TranscriptLogRowPreview() {
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);

  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Collapsed (tap to expand)</Text>
      <Pressable
        onPress={() => setExpanded((value) => !value)}
        accessibilityRole="button"
        accessibilityState={{ expanded }}
        accessibilityLabel="Ran npm test, 42 passed"
        style={preview.logRow}
      >
        <View style={preview.logIconSlot}>
          <Text>🛠️</Text>
        </View>
        <Text style={preview.logSummary} numberOfLines={1}>Ran `npm test` — 42 passed</Text>
        <View style={preview.logTrailingGroup}>
          <DisclosureChevron expanded={expanded} />
          <View style={preview.logStatusSlot}>
            <Icon name="check" size={11} color="#8a8a8a" />
          </View>
        </View>
      </Pressable>
      {expanded && (
        <Pressable
          onLongPress={() => setCopied(true)}
          accessibilityLabel="Log detail. Long-press to copy."
          style={preview.logBody}
        >
          <Text style={preview.logBodyText} numberOfLines={3}>PASS src/App.test.tsx{'\n'}Tests: 42 passed, 42 total</Text>
        </Pressable>
      )}
      {copied && <Text style={preview.caption}>Copied to clipboard (long-press reconstruction).</Text>}

      <Text style={[preview.label, { marginTop: 8 }]}>Expanded (static)</Text>
      <View style={preview.logRow}>
        <View style={preview.logIconSlot}>
          <Text>🛠️</Text>
        </View>
        <Text style={preview.logSummary} numberOfLines={1}>Ran `npm lint` — 1 warning</Text>
        <View style={preview.logTrailingGroup}>
          <DisclosureChevron expanded />
          <View style={preview.logStatusSlot}>
            <Icon name="alert-circle" size={11} color={HERMES_COLOR_RAMPS.Red[500]} />
          </View>
        </View>
      </View>
      <View style={preview.logBody}>
        <Text style={preview.logBodyText} numberOfLines={3}>WARN src/legacy.ts:42{'\n'}'foo' is defined but never used.</Text>
      </View>

      <Text style={preview.caption}>
        Production's three call sites — a tool-call log, the "Thinking" reasoning block (Chat), and
        a bot activity/plan row (Bots) — compose this exact, already-adopted TranscriptLogRowView
        anatomy: icon slot, summary, a chevron, then a compact 16×16 status glyph at the extreme
        trailing edge (a checkmark/xmark/ellipsis in secondary, or red for a failure — never a wide
        status word), and a chevron that expands into a scrollable detail body indented 28pt under the
        row text behind a leading hairline rule. The row itself toggles expand/collapse
        (accessibilityState.expanded); a long press on the expanded body copies its content. The
        shared downward chevron rotates upward when expanded.
      </Text>
    </View>
  );
}

// ─── Transcript Activity pattern (composite, not a single log row) ──────────────
/**
 * A real composite of the pattern's five documented pieces — Turn Summary Disclosure, the Activity
 * Disclosure Row, a grouped-tool-history control, assistant message content, and message metadata —
 * rather than reusing the standalone Disclosure Row preview verbatim. Turn Summary Disclosure and the
 * Activity Disclosure Row share the same interactive-row anatomy as the Disclosure Row entry (real
 * Pressables exposing accessibilityState.expanded), since that shared anatomy is exactly what the
 * approved specification documents; the grouped-tool-history control composes the real Button.
 */
export function TranscriptActivityPreview() {
  const [turnExpanded, setTurnExpanded] = useState(true);
  const [groupExpanded, setGroupExpanded] = useState(false);
  const [logExpanded, setLogExpanded] = useState(false);

  return (
    <PreviewSpecimen
      name="Transcript Activity"
      fill
      details={
        <Text style={preview.detailsText}>
          Domain ownership boundary preserved: turn-folding logic, assistant message content rendering,
          and message metadata stay owned by their existing production types — this composite only
          documents how Turn Summary Disclosure, the Activity Disclosure Row, the grouped-tool-history
          control, assistant message content, and message metadata relate to each other.
        </Text>
      }
    >
      <Text style={preview.label}>Turn Summary Disclosure</Text>
      <Pressable
        onPress={() => setTurnExpanded((value) => !value)}
        accessibilityRole="button"
        accessibilityState={{ expanded: turnExpanded }}
        accessibilityLabel="Turn summary: ran tests and fixed the failing case"
        style={preview.logRow}
      >
        <View style={preview.logIconSlot}><Text>✦</Text></View>
        <Text style={preview.logSummary} numberOfLines={1}>Ran tests and fixed the failing case</Text>
        <DisclosureChevron expanded={turnExpanded} />
      </Pressable>

      {turnExpanded && (
        <View style={{ marginLeft: 26, gap: 10 }}>
          <Text style={preview.label}>Activity Disclosure Row — "Thinking" reasoning block</Text>
          <Pressable
            onPress={() => setLogExpanded((value) => !value)}
            accessibilityRole="button"
            accessibilityState={{ expanded: logExpanded }}
            accessibilityLabel="Thinking"
            style={preview.logRow}
          >
            <View style={preview.logIconSlot}><Text>🛠️</Text></View>
            <Text style={preview.logSummary} numberOfLines={1}>Ran `npm test` — 42 passed</Text>
            <View style={preview.logTrailingGroup}>
              <DisclosureChevron expanded={logExpanded} />
              <View style={preview.logStatusSlot}>
                <Icon name="check" size={11} color="#8a8a8a" />
              </View>
            </View>
          </Pressable>
          {logExpanded && (
            <View style={preview.logBody}>
              <Text style={preview.logBodyText} numberOfLines={3}>PASS src/App.test.tsx{'\n'}Tests: 42 passed, 42 total</Text>
            </View>
          )}

          <Text style={preview.label}>Grouped-tool-history control</Text>
          <Button
            label={groupExpanded ? 'Hide tool calls' : 'Show 3 more tool calls'}
            variant="tertiary"
            size="small"
            onPress={() => setGroupExpanded((value) => !value)}
          />
          {groupExpanded && (
            <View style={{ gap: 4 }}>
              <Text style={preview.caption}>Read App.tsx</Text>
              <Text style={preview.caption}>Edit App.test.tsx</Text>
              <Text style={preview.caption}>Run `npm test`</Text>
            </View>
          )}

          <Text style={preview.label}>Assistant message content · Message metadata</Text>
          <Text style={preview.composerInputText}>
            All tests are passing now — I fixed the off-by-one in the pagination helper.
          </Text>
          <Text style={preview.caption}>Claude Opus 5 · 12:04 PM</Text>
        </View>
      )}
    </PreviewSpecimen>
  );
}

// ─── Composer pattern (recon mock, not the production composer) ─────────────────
/**
 * A recon mock of the composer surface that composes every family the approved specification
 * assigns it — the real Card (density="compact") for its Attachment tile, an inline Composer Chip
 * example rendered within ordinary text (production's real ComposerChipToken/ComposerChipRendering/
 * ComposerChipTextView subsystem, not a standalone HermexComposerChip), a native-style TextInput
 * reconstruction for text entry (production's own composer text entry is a UIKit UITextView, not the
 * generic template InputField), the real Button for the send action, and a Tag status — rather than
 * standing several of them in for plain View/Text.
 */
export function ComposerPatternPreview() {
  const [composerText, setComposerText] = useState('');
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Composer surface (Adaptive Glass treatment)</Text>
      <View style={preview.composerSurface}>
        <View style={preview.row}>
          <Card density="compact" style={preview.messageFileTile}>
            <View
              style={[
                preview.fileIconPanel,
                { width: HERMES_ATTACHMENT_SIZE.fileIconPanelWidth, height: HERMES_ATTACHMENT_SIZE.fileIconPanelHeight, backgroundColor: HERMES_COLOR_RAMPS.Blue[100] },
              ]}
            >
              <Icon name="paperclip" size={HERMES_ICON_SIZE.extraLarge} color={HERMES_COLOR_RAMPS.Blue[500]} />
              <Text style={[preview.tileExt, { color: HERMES_COLOR_RAMPS.Blue[500] }]}>MD</Text>
            </View>
            <View style={preview.composerTileText}>
              <Text style={preview.composerTileName} numberOfLines={1}>notes.md</Text>
            </View>
          </Card>
        </View>
        <Text style={preview.composerChipRow}>
          <Text style={preview.label}>Composer Chip example (inline with text): </Text>
          <Text>Run </Text>
          <Text style={preview.composerChipInline}>#run-tests</Text>
          <Text> before merging.</Text>
        </Text>
        <View style={preview.composerTextInputRow}>
          <Icon name="menu" size={HERMES_ICON_SIZE.small} color="#6d6d72" />
          <TextInput
            value={composerText}
            onChangeText={setComposerText}
            placeholder="Message @release-bot about #run-tests…"
            accessibilityLabel="Message"
            style={preview.nativeSearchInput}
          />
        </View>
        <View style={preview.composerActionsRow}>
          <View style={preview.tagRow}>
            <TagSwatch label="Draft saved" tint="#8E8E93" hPad={6} vPad={2} />
          </View>
          <Button
            label="Send"
            showIcon
            showLabel={false}
            iconName="add"
            size="medium"
            variant="primary"
            onPress={() => {}}
          />
        </View>
        <Text style={preview.composerValidationText}>Message too long — trim before sending.</Text>
      </View>
      <Text style={preview.caption}>
        A recon mock of the composer surface — an Adaptive Glass background, a Compact-Card
        Attachment tile, an inline Composer Chip example, a native-style text input reconstruction,
        the real Button, a Tag status, and validation feedback — not the production composer. Text
        editing, keyboard interaction, draft persistence, attachments, runtime selection, voice input,
        and send/stop lifecycle stay owned by the production Composer pattern.
      </Text>
    </View>
  );
}

// ─── Composer Toolbar (new, foundation-available, zero-adoption) ────────────────
/**
 * A reconstruction of `HermexComposerToolbar.swift`: one horizontally scrollable row that accepts
 * arbitrary caller content, in its elevated (own surface/radius/shadow) and transparent (no owned
 * chrome) appearances, at both a fitting and an overflowing content width. Deliberately demonstrates
 * only generic secondary controls — never a Send or Stop action, which this shared foundation never
 * owns.
 */
export function ComposerToolbarFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen name="Elevated — fitting content" fill>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={preview.composerToolbarElevated}>
        <View style={preview.row}>
          <Button label="Model" size="small" variant="secondary" onPress={() => {}} />
          <Button label="Profile" size="small" variant="secondary" onPress={() => {}} />
        </View>
      </ScrollView>
      </PreviewSpecimen>
      <PreviewSpecimen name="Elevated — overflowing content" fill>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={preview.composerToolbarElevated}>
        <View style={[preview.row, preview.composerToolbarOverflowContent]}>
          {['Model', 'Profile', 'Branch', 'History', 'Settings'].map((label) => (
            <Button key={label} label={label} size="small" variant="secondary" onPress={() => {}} />
          ))}
        </View>
      </ScrollView>
      </PreviewSpecimen>
      <PreviewSpecimen name="Transparent — inside Card" fill>
      <Card density="compact" style={{ width: '100%' }}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          <View style={preview.row}>
            <Button label="Model" size="small" variant="secondary" onPress={() => {}} />
            <Button label="Profile" size="small" variant="secondary" onPress={() => {}} />
          </View>
        </ScrollView>
      </Card>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Elevated · Divider"
        fill
        details={
          <Text style={preview.detailsText}>
            One `ScrollView(.horizontal)` row with `HermesSpacing.s8` padding on all sides (not only
            horizontal) and edge fades that reveal only where content is hidden behind that edge, with a
            Reduce-Motion-safe fade animation. Elevated draws its own adaptive surface, `HermesRadius.r24`
            radius, and shadow; transparent leaves the surface to the caller (here, a Card). Arbitrary
            caller content — never a Send or Stop control, which this shared foundation never
            demonstrates or owns. A caller inserts `HermexComposerToolbarDivider` explicitly between
            logical control groups (last example) — a hairline, 24pt-tall, vertically centered, decorative
            divider that scrolls with the row's own content; the toolbar never inserts one automatically.
            Foundation-available; zero production screens have adopted it — the current Chat/Bots composer
            toolbars keep their own separate, feature-local ComposerToolbarScroller unchanged.
          </Text>
        }
      >
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={preview.composerToolbarElevated}>
        <View style={preview.row}>
          <Button label="Model" size="small" variant="secondary" onPress={() => {}} />
          <Button label="Profile" size="small" variant="secondary" onPress={() => {}} />
          <Divider style={preview.composerToolbarDivider} />
          <Button label="Branch" size="small" variant="secondary" onPress={() => {}} />
        </View>
      </ScrollView>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Elevated — mixed content"
        fill
        details={
          <Text style={preview.detailsText}>
            The content slot is one ordered, zero-or-more arbitrary-content slot, not a button-only
            concept: the toolbar owns horizontal ordering, spacing, scrolling, and fades, while each
            child owns its own semantics, interaction, and minimum hit target. Mixes a display-only
            Tag/pill-like specimen (the same reconstruction demonstrated in the Tag family, never
            tappable) alongside a real Button control in the same row.
          </Text>
        }
      >
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={preview.composerToolbarElevated}>
        <View style={preview.row}>
          <TagSwatch label="Draft" tint="#8E8E93" hPad={8} vPad={2} />
          <Button label="Model" size="small" variant="secondary" onPress={() => {}} />
        </View>
      </ScrollView>
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Toast ─────────────────────────────────────────────────────────────────────
// A real control toggling the generic Toast's own `visible` prop, so the top-edge slide + opacity
// transition is replayable in the running preview rather than only described in prose.
function ToastMotionDemo() {
  const [visible, setVisible] = useState(true);
  return (
    <View style={{ gap: 8, alignItems: 'flex-start' }}>
      <Button label={visible ? 'Hide' : 'Show'} size="small" variant="secondary" onPress={() => setVisible((v) => !v)} />
      <Toast
        message="Synced with server"
        iconName="circle-check"
        style={{ backgroundColor: HERMES_COLOR_RAMPS.Green[800] }}
        visible={visible}
        showDivider={false}
      />
    </View>
  );
}

export function ToastFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Motion"
        fill
        details={<Text style={preview.detailsText}>Tap the button to replay the Toast's slide-in/out.</Text>}
      >
      <ToastMotionDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Dark semantic surfaces"
        fill
        details={
          <Text style={preview.detailsText}>
            HermexToast's own dark semantic ramp, with white icon/message content.
          </Text>
        }
      >
      <View style={{ gap: 8 }}>
        <Toast message="Synced with server" iconName="circle-check" style={{ backgroundColor: HERMES_COLOR_RAMPS.Green[800] }} showDivider={false} />
        <Toast message="Cached offline data may be stale" iconName="info" style={{ backgroundColor: HERMES_COLOR_RAMPS.Blue[700] }} showDivider={false} />
        <Toast message="Reconnecting…" iconName="triangle-alert" style={{ backgroundColor: HERMES_COLOR_RAMPS.Orange[800] }} showDivider={false} />
        <Toast message="Could not send message" iconName="circle-slash" style={{ backgroundColor: HERMES_COLOR_RAMPS.Red[700] }} showDivider={false} />
      </View>
      </PreviewSpecimen>
      <PreviewSpecimen
        name="With a trailing action"
        fill
        details={
          <Text style={preview.detailsText}>
            The generic catalog Toast owns its own slide-in/out animation directly on `visible`.
            Production HermexToast is the message/icon/action card alone — animation and lifecycle live
            in the separate `hermexToast(isPresented:toast:)` presentation modifier that overlays it, left
            entirely caller-owned rather than baked into the toast view itself. That modifier's default
            motion enters by moving down from the top edge combined with opacity and exits back toward
            the top combined with opacity, reusing the shared overlayEnter/overlayExit motion bundles;
            Reduce Motion drops the move and falls back to an opacity-only state change. Each surface
            above overrides the generic Toast's own light-tinted `variant` styles with the exact fixed
            ramp step HermexToast uses natively — Blue.s700 (information), Green.s800 (success),
            Orange.s800 (warning), and Red.s700 (error) — leaving its default white icon/message/action
            colors untouched, since no `variant` is passed. HermexToast's own trailing action is a plain
            white `Button(action.title)`, styled `.foregroundStyle(.white)`, never a filled capsule or a
            separate neutral-button composition, and keeps a 44pt minimum tap target via the generic
            ghost Button's own hitSlop. `showDivider={false}` on every specimen above matches
            HermexToast's own anatomy — icon, message, Spacer, action — which separates message from
            action by spacing alone, never a divider.
          </Text>
        }
      >
      <Toast
        message="Session archived"
        iconName="circle-check"
        style={{ backgroundColor: HERMES_COLOR_RAMPS.Green[800] }}
        action={{ label: 'Undo', onPress: () => {} }}
        showDivider={false}
      />
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}

// ─── Tooltip ───────────────────────────────────────────────────────────────────
function TooltipInteractiveDemo() {
  const [visible, setVisible] = useState(false);
  return (
    <View style={{ alignItems: 'flex-start', paddingTop: 8 }}>
      <Tooltip visible={visible} label="Explanatory content, wrapped to fit">
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="More information"
          onPressIn={() => setVisible(true)}
          onPressOut={() => setVisible(false)}
        >
          <Icon name="info" size={HERMES_ICON_SIZE.small} color="#8a8a8a" />
        </Pressable>
      </Tooltip>
    </View>
  );
}

// A static reconstruction of the native `.popover` content surface itself — the component's entire
// visual payload — shown inline for inspection the same way the Dialog/Popover Menu/Bottom Sheet
// specimens render their own overlay surfaces statically, rather than only behind an interactive demo.
function TooltipContentSurfacePreview() {
  return (
    <View style={preview.tooltipSurfaceWrap}>
      <View style={preview.tooltipArrow} />
      <View style={preview.tooltipSurface}>
        <Text style={preview.tooltipSurfaceText}>Context window usage resets each session.</Text>
      </View>
    </View>
  );
}

export function TooltipFamilyGallery() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Tap the info glyph to open (no press-and-hold, no hover-only path)</Text>
      <TooltipInteractiveDemo />
      <Text style={[preview.label, { marginTop: 8 }]}>Anchored content surface (static)</Text>
      <TooltipContentSurfacePreview />
      <Text style={preview.caption}>
        The generic catalog Tooltip is a fully-controlled bubble a caller drives from press
        in/out — mobile has no hover. Production HermexTooltip anchors the same explanatory content
        through the native `.popover` presentation path instead of a hand-drawn bubble/arrow, behind
        an explicit tap trigger (a plain Button that opens the popover and leaves it open); dismissal
        is the popover's own native recovery path (tap outside, or Escape on a hardware keyboard)
        rather than a release gesture. The content surface itself is subheadline primary text with
        12pt padding (HermesSpacing.s12), a 280pt max width, and a top arrow edge pointing back at the
        trigger — presentationCompactAdaptation(.none) keeps it a popover on every size class.
      </Text>
    </View>
  );
}

// ─── Radio ─────────────────────────────────────────────────────────────────────
function RadioGroupDemo() {
  const [selected, setSelected] = useState('a');
  return (
    <View style={{ gap: 10 }}>
      <Radio selected={selected === 'a'} onPress={() => setSelected('a')} label="Option A" colors={HERMEX_SELECTION_CONTROL_COLORS} />
      <Radio selected={selected === 'b'} onPress={() => setSelected('b')} label="Option B" colors={HERMEX_SELECTION_CONTROL_COLORS} />
      <Radio selected={selected === 'c'} onPress={() => setSelected('c')} label="Option C" disabled colors={HERMEX_SELECTION_CONTROL_COLORS} />
    </View>
  );
}

export function RadioFamilyGallery() {
  return (
    <View style={preview.stack}>
      <Text style={preview.label}>Unselected · Selected · Disabled</Text>
      <View style={preview.row}>
        <Radio selected={false} onPress={() => {}} label="Unselected" colors={HERMEX_SELECTION_CONTROL_COLORS} />
        <Radio selected={true} onPress={() => {}} label="Selected" colors={HERMEX_SELECTION_CONTROL_COLORS} />
        <Radio selected={false} onPress={() => {}} label="Disabled" disabled colors={HERMEX_SELECTION_CONTROL_COLORS} />
      </View>
      <Text style={[preview.label, { marginTop: 8 }]}>One-of-many group (tap to change selection)</Text>
      <RadioGroupDemo />
      <Text style={preview.caption}>
        A group is just multiple Radio instances sharing one selected value in the caller — the same
        way a native radio group works — this component only knows its own selected state.
      </Text>
      <Text style={[preview.label, { marginTop: 8 }]}>Adaptive selected fill (production HermexRadio)</Text>
      <AdaptiveSelectedFillSwatch shape="circle" />
      <Text style={preview.caption}>
        Production HermexRadio fills the selected ring and inner dot with the adaptive semantic
        Neutral mapping — deep Neutral.s950 in light appearance and near-white Neutral.s50 in dark — not
        a fixed accent color, mirroring HermexCheckbox's own adaptive treatment. Every Radio specimen
        above now passes that same light-appearance mapping via the shared colors prop, matching
        native instead of the reusable template's own unrelated blue default.
      </Text>
    </View>
  );
}

// ─── Selection Sheet ────────────────────────────────────────────────────────────
// Reconstructs `HermexSelectionSheet`'s content only, from existing catalog primitives —
// List/ListItem own the scrolling rows and the single interactive target per row; Radio/Checkbox
// render as row-owned, non-interactive visual indicators (Checkbox already supports this by
// omitting `onChange`; Radio's `onPress` is required in the generic template, so it is wrapped in a
// `pointerEvents="none"` + `accessibilityElementsHidden` View instead — the closest the existing
// seam allows). Native `.sheet` presentation, detents, drag indicator, compact adaptation, and, for
// Search, the query binding/visible-options filtering/loading/errors all stay caller-owned in
// production; this gallery's own wrapping page stands in for that caller.
const SELECTION_SHEET_PROFILE_OPTIONS = [
  { value: 'default', label: 'Default' },
  { value: 'research', label: 'Research' },
  { value: 'coding', label: 'Coding' },
];

const SELECTION_SHEET_SKILL_OPTIONS = [
  { value: 'writing', label: 'Writing' },
  { value: 'research', label: 'Research' },
  { value: 'coding', label: 'Coding' },
];

const SELECTION_SHEET_LONG_LIST_OPTIONS = Array.from({ length: 24 }, (_, i) => ({
  value: `option-${i + 1}`,
  label: `Option ${i + 1}`,
}));

function SelectionSheetRadioIndicator({ selected }: { selected: boolean }) {
  return (
    <View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
      <Radio selected={selected} onPress={() => {}} colors={HERMEX_SELECTION_CONTROL_COLORS} />
    </View>
  );
}

function SelectionSheetSingleDemo() {
  const [committed, setCommitted] = useState('research');
  const committedLabel = SELECTION_SHEET_PROFILE_OPTIONS.find((option) => option.value === committed)?.label;
  return (
    <View style={preview.stack}>
      <List>
        {SELECTION_SHEET_PROFILE_OPTIONS.map((option) => (
          <ListItem
            key={option.value}
            leading={<SelectionSheetRadioIndicator selected={committed === option.value} />}
            title={option.label}
            selected={committed === option.value}
            onPress={() => setCommitted(option.value)}
          />
        ))}
        <ListItem
          leading={<SelectionSheetRadioIndicator selected={false} />}
          title="Locked profile"
          disabled
          onPress={() => {}}
        />
      </List>
      <Text style={preview.caption}>
        Committed value: "{committedLabel}". Tapping an enabled row commits it immediately (the real
        sheet then dismisses); the disabled "Locked profile" row stays visible and announced but never
        commits or dismisses.
      </Text>
    </View>
  );
}

// DSR3-09: multi-selection moves Cancel/Done out of TopNav and into HermexBottomSheet's own pinned
// footer, with an explicit horizontal/vertical `footerAxis` (default horizontal). Horizontal order is
// Cancel then Done; vertical order is Done above Cancel, each stretched full width — reusing the same
// real bottomSheetShell/bottomSheetFooter reconstruction as the Bottom Sheet entry itself, since this
// is now genuinely a Bottom Sheet footer, not a bare row of buttons floating below the list.
function SelectionSheetMultiFooterDemo({ axis }: { axis: 'horizontal' | 'vertical' }) {
  const committedBaseline = ['writing', 'research'];
  const [committed, setCommitted] = useState<string[]>(committedBaseline);
  const [draft, setDraft] = useState<string[]>(committedBaseline);
  const isDirty = draft.slice().sort().join(',') !== committed.slice().sort().join(',');

  const toggle = (value: string) => {
    setDraft((prev) => (prev.includes(value) ? prev.filter((v) => v !== value) : [...prev, value]));
  };

  return (
    // Selection Sheet is a screen-row (fill) family — width: '100%' overrides the shared
    // bottomSheetSpecimen's own fixed 320px, which the (non-fill) Bottom Sheet gallery keeps.
    <View style={[preview.bottomSheetSpecimen, { width: '100%' }]}>
      <View style={preview.bottomSheetShell}>
        <View style={preview.bottomSheetBody}>
          <List>
            {SELECTION_SHEET_SKILL_OPTIONS.map((option) => (
              <ListItem
                key={option.value}
                leading={<Checkbox checked={draft.includes(option.value)} colors={HERMEX_SELECTION_CONTROL_COLORS} />}
                title={option.label}
                selected={draft.includes(option.value)}
                onPress={() => toggle(option.value)}
              />
            ))}
          </List>
        </View>
        <View style={[preview.bottomSheetFooter, axis === 'vertical' && preview.bottomSheetFooterVertical]}>
          {axis === 'horizontal' ? (
            <>
              <Button variant="secondary" label="Cancel" onPress={() => setDraft(committed)} style={[preview.bottomSheetFooterButton, preview.buttonSecondaryBordered]} />
              <Button variant="primary" label="Done" onPress={() => setCommitted(draft)} style={preview.bottomSheetFooterButton} />
            </>
          ) : (
            <>
              <Button variant="primary" label="Done" onPress={() => setCommitted(draft)} style={preview.bottomSheetFooterButtonFull} />
              <Button variant="secondary" label="Cancel" onPress={() => setDraft(committed)} style={[preview.bottomSheetFooterButtonFull, preview.buttonSecondaryBordered]} />
            </>
          )}
        </View>
      </View>
      <Text style={preview.caption}>
        Row taps edit only the local draft — {isDirty ? 'dirty: draft differs from the committed baseline' : 'clean: draft matches the committed baseline'}.
        Committed: {committed.join(', ') || 'none'}. Cancel discards the draft back to that committed
        baseline; Done replaces the committed baseline with the current draft exactly once.
      </Text>
    </View>
  );
}

function SelectionSheetSearchDemo() {
  const [query, setQuery] = useState('');
  const [isFocused, setIsFocused] = useState(false);
  const searchInputRef = useRef<TextInput>(null);
  const trimmed = query.trim().toLowerCase();
  const visibleOptions = trimmed.length === 0
    ? SELECTION_SHEET_PROFILE_OPTIONS
    : SELECTION_SHEET_PROFILE_OPTIONS.filter((option) => option.label.toLowerCase().includes(trimmed));
  return (
    <View style={preview.stack}>
      <View style={[preview.searchField, isFocused && preview.searchFieldFocused]} accessibilityRole="search">
        <Icon name="search" size={DS_ICON_SIZE.sm} color="#6d6d72" />
        <TextInput
          ref={searchInputRef}
          value={query}
          onChangeText={setQuery}
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          placeholder="Search profiles"
          accessibilityLabel="Search profiles"
          style={preview.searchFieldInput}
        />
        {query.length > 0 && (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Clear search"
            style={[preview.searchClearTarget, { minWidth: 44, minHeight: 44 }]}
            onPress={() => {
              setQuery('');
              searchInputRef.current?.focus();
            }}
          >
            <Icon name="clear" size={DS_ICON_SIZE.sm} color="#6d6d72" />
          </Pressable>
        )}
      </View>
      {visibleOptions.length > 0 ? (
        <List>
          {visibleOptions.map((option) => (
            <ListItem key={option.value} title={option.label} onPress={() => {}} />
          ))}
        </List>
      ) : (
        <Text style={preview.caption}>No results</Text>
      )}
    </View>
  );
}

function SelectionSheetLongListDemo() {
  const [selected, setSelected] = useState('option-1');
  return (
    <View style={preview.stack}>
      <List variant="compactOverlay" maxHeight={240} style={preview.compactOverlayDemoList}>
        {SELECTION_SHEET_LONG_LIST_OPTIONS.map((option) => (
          <ListItem
            key={option.value}
            leading={<SelectionSheetRadioIndicator selected={selected === option.value} />}
            title={option.label}
            selected={selected === option.value}
            onPress={() => setSelected(option.value)}
          />
        ))}
      </List>
    </View>
  );
}

export function SelectionSheetFamilyGallery() {
  return (
    <PreviewSpecimenGrid>
      <PreviewSpecimen
        name="Single selection"
        fill
        details={
          <Text style={preview.detailsText}>
            Shows the current value, commit-on-tap selection, and a disabled option.
          </Text>
        }
      >
      <SelectionSheetSingleDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Multi selection · Horizontal footer"
        fill
        details={
          <Text style={preview.detailsText}>
            Selections stage as a draft; Cancel discards the draft, Done commits it.
          </Text>
        }
      >
      <SelectionSheetMultiFooterDemo axis="horizontal" />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Multi selection · Vertical footer"
        fill
        details={
          <Text style={preview.detailsText}>
            Selections stage as a draft; Cancel discards the draft, Done commits it.
          </Text>
        }
      >
      <SelectionSheetMultiFooterDemo axis="vertical" />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Optional caller-controlled Search"
        fill
        details={
          <Text style={preview.detailsText}>
            The caller owns the query binding and filters the visible options array it passes in —
            Selection Sheet never matches, debounces, or loads results on its own. Clearing the query
            restores every option; an unmatched query shows this exact generic copy, "No results", never
            echoing the query back.
          </Text>
        }
      >
      <SelectionSheetSearchDemo />
      </PreviewSpecimen>
      <PreviewSpecimen
        name="Long list · 24 options"
        fill
        details={
          <Text style={preview.detailsText}>
            24 options — past the 20-option threshold — inside a bounded, internally scrolling list.
            Every specimen above reconstructs `HermexSelectionSheet`'s presented content only. Native
            `.sheet` presentation, detents, drag indicator, compact adaptation, and — for Search — the
            query binding, visible-options filtering, loading, and error state all stay caller-owned in
            production; this gallery's own wrapping page is standing in for that caller, not for a second
            presentation system. Multi-selection's Cancel/Done now live in the sheet's own pinned footer
            (not TopNav), with an explicit `footerAxis`: horizontal orders Cancel then Done; vertical
            orders Done above Cancel, each stretched full width.
          </Text>
        }
      >
      <SelectionSheetLongListDemo />
      </PreviewSpecimen>
    </PreviewSpecimenGrid>
  );
}
