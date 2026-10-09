/**
 * Hermex reference layer.
 *
 * This file documents the in-repository Design System candidate. Most new tokens/components remain
 * foundation-only; bounded production adoptions are named explicitly in `HermesOverview` and each
 * entry's adoption metadata. Every `SectionDef` below documents a Hermex-sourced catalog entry: a concise
 * plain-English introduction and visual examples first, then "Product context" destinations —
 * relevant screens/paths a reader can use to picture where a component fits, not proof of current
 * production adoption unless the entry's own `implementationNotes.status` says so — with technical
 * provenance (source paths, foundation/adoption status, material-fidelity notes) visible in the
 * lower reference-details cards (see `def.hermesReference`, `native/catalog/types.ts`).
 * Hermex itself ships no React Native runtime — every live example on this page is a React Native
 * documentation reconstruction of SwiftUI source, not the production app.
 *
 * This file only supplies data; layout/columns/scroll-spy belong to the shared catalog framework
 * (`CatalogShell`/`SectionBlock`), the same as the retained template catalog in `../CatalogExample`.
 */
import { useState } from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { Avatar, Button, Card, SegmentedToggle } from '../../components';
import { DividedStack } from '../DividedStack';
import { VariantGroup } from '../VariantGroup';
import { Swatch } from '../Swatch';
import { TokenRow } from '../TokenRow';
import { TypeScaleGallery } from '../TypeScaleGallery';
import type { NavGroup, SectionDef } from '../types';
import { buildHermesManifestEnvelope } from '../manifest';
import { HERMES_COLOR_RAMPS, HERMES_COLOR_RAMP_STEPS, HERMES_COLOR_GENERATED_STEP_CONSUMPTION_RESTRICTION } from './hermesColorCatalogData';
import { HermesSemanticColorReference } from './HermesSemanticColorReference';
import { HermesIconReference } from './HermesIconReference';
import { HermesMotionReference } from './HermesMotionReference';
import { HermesOverviewImplementationDetails } from './HermesReferenceDetails';
import { SpacingScaleGallery } from '../SpacingScaleGallery';
import { HERMES_SPACING_STEPS, HERMES_SPACING, HERMES_SPACING_USE, HERMES_MOTION_BUNDLES, HERMES_MOTION_EASING } from './hermesTokenProposal';
import { HERMES_ATTACHMENT_SIZE } from './hermesAttachmentSize';
import { HERMES_ICON_SIZE } from './hermesIconSize';
import { HERMES_ICON_TYPOGRAPHY_PAIRING, HERMES_ICON_AVATAR_PAIRING } from './hermesIconSize';
import {
  AccordionListFamilyGallery,
  AttachmentTileGallery,
  AvatarSystemImageIdentityPreview,
  BannerFamilyGallery,
  BotMarkPreview,
  ButtonDecisionAndTactilePreview,
  CheckboxFamilyGallery,
  ComposerPatternPreview,
  ComposerToolbarFamilyGallery,
  DialogFamilyGallery,
  HermexBottomSheetFamilyGallery,
  HermexDividerPreview,
  HermesSkeletonGallery,
  HermexTextInputFamilyGallery,
  ListItemFamilyGallery,
  PopoverMenuFamilyGallery,
  RadioFamilyGallery,
  SearchFamilyGallery,
  SegmentedControlGallery,
  SelectionSheetFamilyGallery,
  TagGallery,
  ToastFamilyGallery,
  TooltipFamilyGallery,
  TopNavFamilyGallery,
  TranscriptActivityPreview,
  TranscriptLogRowPreview,
} from './HermesComponentFamiliesPreviews';

// Ids below are internal keys only — never rendered directly. Sections combine into one flat array
// with the retained template catalog's own sections (see HermesDesignSystemCatalog.tsx), which
// already owns the bare 'Card' / 'Banner' / 'Checkbox' / 'Avatar' / 'TopNav' ids for its own
// unrelated entries — reusing those exact strings here would silently collide in that shared
// id-keyed lookup. Renamed Components-family entries instead keep a unique 'Hermes <Name>' id (the
// internal engineering namespace already used throughout, e.g. HermexCard.swift) and set their own
// `displayName` to the plain catalog name the sidebar/title actually show — see `SectionDef.
// displayName` in ../types.ts. Foundations/token entries also keep their existing namespaced
// 'Hermex …' ids for stable lookup while using plain visible names such as 'Colors' and 'Spacing'.
export type HermesSectionId =
  | 'Hermex Typography'
  | 'Hermex Font'
  | 'Adaptive Glass'
  | 'Hermes Card'
  | 'Attachment'
  | 'Hermes Banner'
  | 'Hermes Avatar'
  | 'Row Divider'
  | 'Tag'
  | 'Search'
  | 'Text Input'
  | 'Bottom Sheet'
  | 'Hermes Dialog'
  | 'Hermes Popover Menu'
  | 'Segmented Control'
  | 'Buttons'
  | 'Hermes Checkbox'
  | 'Hermes Radio'
  | 'Hermes Selection Sheet'
  | 'Hermes Toast'
  | 'Hermes Tooltip'
  | 'Hermes TopNav'
  | 'Skeleton Loading'
  | 'List / ListItem'
  | 'Accordion List'
  | 'Transcript Log Row'
  | 'Composer Toolbar'
  | 'Content Unavailable'
  | 'Pending Request'
  | 'Transcript Activity'
  | 'Composer'
  | 'Hermex Colors'
  | 'Hermex Motion'
  | 'Hermex Radius & Geometry'
  | 'Hermex Spacing'
  | 'Hermex Shadow'
  | 'Hermex Iconography';

// The Card family's approved Neutral color mapping (DSF-07), mirroring native HermexCardColors:
// every Card variant's background resolves to one of these pairs instead of a hand-typed rgba/hex
// literal. This catalog renders one static (light) appearance, so only the light anchor of each
// adaptive pair is used; native's dark counterpart is a documented follow-up, not asserted here.
// Border color is NOT a HermexCardColors role — native HermexCard.swift resolves every variant's
// border through the separate, shared HermexSurfaceBorderColors (reconstructed below as
// HERMEX_SURFACE_BORDER_COLORS), so this object defines only the two real surface roles.
const HERMEX_CARD_COLORS = {
  primarySurface: HERMES_COLOR_RAMPS.Neutral[50],
  secondarySurface: HERMES_COLOR_RAMPS.Neutral[100],
};

// Round 2 shared border reconstruction, mirroring native HermexSurfaceBorderColors: Card, Search,
// Text Input, and Code Input specimens all reuse this one resting/focused/increasedContrast mapping
// instead of each specimen re-deriving its own border literal.
const HERMEX_SURFACE_BORDER_COLORS = {
  resting: HERMES_COLOR_RAMPS.Neutral[600],
  focused: HERMES_COLOR_RAMPS.Neutral[700],
  increasedContrast: HERMES_COLOR_RAMPS.Neutral[800],
};

// ─── Reconstruction chrome ───────────────────────────────────────────────────
// Approximates the exact numbers found in Hermex's SwiftUI source (corner radius, opacity, stroke
// weight/opacity, padding) — deliberately NOT this repo's own RN template tokens, which belong to
// an unrelated brand and would misrepresent Hermex's real values. Local to this file.
const recon = StyleSheet.create({
  stack: { gap: 12 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 12 },
  note: { fontSize: 11, color: '#8a8a8a', fontStyle: 'italic', marginTop: 4 },
  caption: { fontSize: 11, color: '#8a8a8a', lineHeight: 16 },
  motionName: { fontSize: 12, fontWeight: '700', color: '#1c1c1e', minWidth: 190 },
  motionValue: { fontSize: 11, color: '#3a3a3c', fontFamily: 'Menlo' },
  radiusCell: { alignItems: 'center', gap: 4, width: 84 },
  radiusBox: { width: 48, height: 48, backgroundColor: '#e3e3e6', borderWidth: 1, borderColor: 'rgba(0,0,0,0.12)' },
  radiusList: { gap: 4 },
  glassBox: { width: 132, height: 64, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  glassLiquid: { backgroundColor: 'rgba(255,255,255,0.55)', borderWidth: 1, borderColor: 'rgba(0,0,0,0.08)' },
  glassMaterial: { backgroundColor: 'rgba(240,240,245,0.85)', borderWidth: 1, borderColor: 'rgba(0,0,0,0.10)' },
  glassOpaque: { backgroundColor: '#efeff4', borderWidth: 1, borderColor: 'rgba(0,0,0,0.14)' },
  glassLabel: { fontSize: 12, fontWeight: '600', color: '#1c1c1e' },
  strokeBox: { width: 160, height: 48, borderRadius: 12, backgroundColor: '#f5f5f7', alignItems: 'center', justifyContent: 'center' },
  strokeThin: { borderWidth: 1, borderColor: 'rgba(0,0,0,0.14)' },
  strokeThick: { borderWidth: 1, borderColor: 'rgba(0,0,0,0.22)' },
  cuvStack: { alignItems: 'center', gap: 8, padding: 16, width: 220 },
  cuvIconSlot: {
    width: 44, height: 44, borderRadius: 22, backgroundColor: '#efeff4',
    alignItems: 'center', justifyContent: 'center',
  },
  cuvIconGlyph: { fontSize: 18, color: '#8a8a8a' },
  cuvSpinnerGlyph: { fontSize: 26, color: '#8a8a8a' },
  cuvTitle: { fontSize: 15, fontWeight: '600', color: '#1c1c1e', textAlign: 'center' },
  cuvDesc: { fontSize: 13, color: '#6d6d72', textAlign: 'center' },
  // A bounded, phone-like frame (fixed width/height, rounded corners) for the .fullScreen Layout
  // specimen below — unlike cuvStack's own hug-content sizing, this needs a real finite container to
  // demonstrate "content starts ~1/3 down the available height" against.
  cuvFullScreenFrame: {
    width: 220, height: 420, borderRadius: 28, borderWidth: 1, borderColor: 'rgba(0,0,0,0.14)',
    backgroundColor: '#ffffff', overflow: 'hidden', alignItems: 'center',
  },
  // Reserves the top third of cuvFullScreenFrame's own height — the same fraction
  // HermexContentUnavailable.swift's .fullScreen case computes via GeometryReader's `proxy.size.height / 3`.
  cuvFullScreenTopSpacer: { height: 420 / 3 },
  cuvFullScreenContent: { alignItems: 'center', gap: 8, paddingHorizontal: 16 },
  prCard: { width: '100%', padding: 14, borderRadius: 26, backgroundColor: '#f2f2f7', borderWidth: 1, borderColor: 'rgba(0,0,0,0.10)' },
  prBlock: { width: '100%', padding: 12, borderRadius: 12, backgroundColor: 'rgba(0,0,0,0.05)' },
  prField: { width: '100%', padding: 12, borderRadius: 14, backgroundColor: '#ffffff', borderWidth: 1, borderColor: 'rgba(0,0,0,0.14)' },
  prChoiceGlass: { width: '100%', padding: 12, borderRadius: 14, backgroundColor: 'rgba(240,240,245,0.85)' },
  prChoiceOpaque: { width: '100%', padding: 12, borderRadius: 14, backgroundColor: '#f8f8f8', borderWidth: 1, borderColor: '#c6c6c8' },
  prText: { fontSize: 13, color: '#3a3a3c' },
  cardBox: { width: 240, borderRadius: 18, backgroundColor: HERMEX_CARD_COLORS.primarySurface, borderWidth: 0.7, borderColor: HERMEX_SURFACE_BORDER_COLORS.resting },
  cardBoxOpaque: { backgroundColor: HERMEX_CARD_COLORS.primarySurface, borderWidth: 1, borderColor: HERMEX_SURFACE_BORDER_COLORS.resting },
  cardTitle: { fontSize: 11, fontWeight: '600', color: '#6d6d72', textTransform: 'uppercase', letterSpacing: 0.5, paddingHorizontal: 4, marginBottom: 8 },
  // Ordinary inline content label for Request/Compact — deliberately NOT cardTitle's uppercase/
  // letter-spaced/secondary-colored SectionCard caption treatment, since neither surface modifier
  // owns a title slot of its own (see CardChromePreview's own comment).
  cardInlineLabel: { fontSize: 13, fontWeight: '600', color: '#1c1c1e', marginBottom: 4 },
  // Neutralizes the real Card's own background/shadow chrome so this recon's own tinted/opaque
  // surface (cardBox/cardBoxOpaque above) stays the visible surface — the real Card is composed here
  // purely for its actual density behavior (default 16pt vs. explicit compact padding), not its look.
  cardTransparentSurface: { backgroundColor: 'transparent', shadowOpacity: 0, elevation: 0, width: '100%' },
  cardOutlinedPreview: { width: 240 },
  cardBody: { fontSize: 13, color: '#3a3a3c' },
  cardFooterDivider: { height: StyleSheet.hairlineWidth, backgroundColor: 'rgba(0,0,0,0.14)' },
  cardFooter: { paddingHorizontal: 16, paddingVertical: 10 },
  cardFooterText: { fontSize: 12, color: '#3478F6', fontWeight: '600' },
  avatarRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  avatarRing: { borderRadius: 999, borderWidth: 1, borderColor: 'rgba(255,255,255,0.18)' },
  avatarLabel: { fontSize: 12, color: '#3a3a3c', flexShrink: 1 },
  avatarCell: { alignItems: 'center', gap: 4, width: 84 },
  avatarGallery: { width: '100%', minWidth: 0 },
  avatarPreviewRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 12, width: '100%', minWidth: 0 },
  avatarIdentityItem: { maxWidth: '100%', minWidth: 0, flexShrink: 1 },
  // Hermex Shadow preview — one card per HermesShadow case; the swatch's native shadow props
  // approximate the resolved appearance, mapped to an equivalent CSS box-shadow on web.
  shadowCard: { width: 136, gap: 6, alignItems: 'center' },
  shadowSwatch: {
    width: 96, height: 64, borderRadius: 10, backgroundColor: '#ffffff',
    borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.08)',
  },
  shadowSwatchDark: { backgroundColor: '#1c1c1e' },
  shadowName: { fontSize: 12, fontWeight: '700', color: '#1c1c1e', textAlign: 'center' },
  shadowValue: { fontSize: 10, color: '#6d6d72', fontFamily: 'Menlo', textAlign: 'center' },
});

// ─── Overview ───────────────────────────────────────────────────────────────
// Rendered by `HermesDesignSystemCatalog` through `CatalogShell`'s `intro` slot — above the first
// nav group, not as its own `SectionDef` — so it never claims a sidebar link or scroll-spy target
// of its own.

// Compact, truthful branch-status summary — replaces the former screen-by-screen production-
// adoption matrix. This branch is foundation-only: it adds Design System tokens/components to the
// repository candidate, but does not migrate any production screen onto them. (PR #974
// issue correction: AppTheme.swift's HeaderLogoColor briefly sourced its hex values from the new
// HermesProductPalette token; it has been disconnected back to its own exact literal hex strings, so
// there is no production-adoption exception to name here anymore.)
interface FoundationStatusRow {
  area: string;
  note: string;
}
const FOUNDATION_BRANCH_STATUS: FoundationStatusRow[] = [
  { area: 'Tokens (Colors, Spacing, Motion, Radius & Geometry, Shadow, Iconography, Typography, Font)', note: 'Defined and available in this branch\'s foundation layer. No production screen reads from them.' },
  { area: 'Components (Card, Button, Checkbox, Radio, Selection Sheet, Toast, Tooltip, TopNav, Avatar, Divider, Banner, Tag, Attachment, Skeleton, List/ListItem, Composer Toolbar, Segmented Control)', note: 'Implemented and available in this branch\'s foundation layer, with SwiftUI unit-test coverage. New families, including HermexBanner, remain foundation-only. Transcript Log Row documents the pre-existing production TranscriptLogRowView; every entry below states its own adoption status.' },
  { area: 'Patterns (Content Unavailable) and pre-existing patterns (Adaptive Glass, Pending Request, Composer, Transcript Activity)', note: 'Content Unavailable is the same story as the components above — a new, unadopted foundation candidate. Adaptive Glass and the Pending Request surfaces predate this branch and remain genuinely in production use; their entries describe that existing, unchanged production reality.' },
];

function HermesFoundationBranchStatusTable() {
  return (
    <VariantGroup name="Branch status — by area" align="left">
      <View style={recon.stack}>
        {FOUNDATION_BRANCH_STATUS.map((row, i) => (
          <TokenRow key={row.area} use={row.note} last={i === FOUNDATION_BRANCH_STATUS.length - 1}>
            <Text style={recon.motionName}>{row.area}</Text>
          </TokenRow>
        ))}
      </View>
    </VariantGroup>
  );
}

export function HermesOverview() {
  return (
    <View style={recon.stack}>
      <Text style={overview.p}>
        <Text style={overview.b}>Implementation status:</Text> this catalog documents the Design System
        candidate in the current working tree. Most new foundations remain unadopted; bounded production
        adoptions are named by each entry's adoption status. The catalog is versioned under{' '}
        <Text style={overview.code}>design-system-catalog/</Text> in the same repository — not maintained
        outside it — and is validated with the application's Design System Contract CI job.
      </Text>
      <Text style={overview.p}>
        Foundation APIs/components/tokens are available in the current repository candidate. Existing
        production use and any bounded migration in this work are stated explicitly per entry.
      </Text>
      <Text style={overview.p}>
        Hermex is SwiftUI. Every live example below is a React Native documentation reconstruction
        built from reading that SwiftUI source, not the production SwiftUI runtime.
      </Text>
      <HermesOverviewImplementationDetails
        meta={{
          implementationNotes: {
            status: 'Repository candidate status only; each entry separately states foundation availability and production adoption. This is not a claim of upstream or App Store release.',
            sourcePaths: ['design-system-catalog/native/catalog/hermes/hermesSections.tsx'],
            notes: [
              'This table is a maintainer-facing coverage summary, not part of the primary design reference.',
            ],
          },
        }}
        implementationContent={<HermesTokenCoverageTable />}
      />
      <Text style={overview.p}>
        <Text style={overview.b}>Branch status:</Text> a compact, truthful summary of what this branch
        actually changes — new tokens/components are available in the repository candidate, and bounded
        production adoptions are named explicitly below. It is not a per-screen adoption audit;
        production source remains the authority on what each screen actually renders.
      </Text>
      <HermesOverviewImplementationDetails
        meta={{
          implementationNotes: {
            status: 'Repository candidate summary; entry-level metadata and production source remain the authority on adoption.',
            notes: [
              'Verified against the current repository source at the time this table was written; re-check before relying on it after further changes.',
            ],
          },
        }}
        implementationContent={<HermesFoundationBranchStatusTable />}
      />
      <Text style={overview.p}>
        <Text style={overview.b}>Machine-readable manifest:</Text> every entry's decision contract
        (Use when / Avoid when / Alternatives / Adoption status) — plus every Foundations token
        gallery — is also available as plain JSON below, for a tool or agent instead of a human.
      </Text>
      <HermesManifest />
    </View>
  );
}

const overview = StyleSheet.create({
  p: { fontSize: 13, color: '#3a3a3c', lineHeight: 19 },
  b: { fontWeight: '700', color: '#1c1c1e' },
  code: { fontFamily: 'Menlo', fontSize: 12 },
});

// ─── Components ───────────────────────────────────────────────────────────────

function GlassSwatch({ label, style }: { label: string; style: object }) {
  return (
    <View style={[recon.glassBox, style]}>
      <Text style={recon.glassLabel}>{label}</Text>
    </View>
  );
}

const CONTENT_UNAVAILABLE_COPY: Record<
  'loading' | 'empty' | 'noResults' | 'error' | 'unavailable' | 'custom',
  { glyph: string; title: string; desc: string }
> = {
  loading: { glyph: '', title: '', desc: 'Loading…' },
  empty: { glyph: '×', title: 'Nothing Here Yet', desc: 'Content will appear here once available.' },
  noResults: { glyph: '?', title: 'No Results', desc: 'Check the spelling or try a new search.' },
  error: { glyph: '!', title: 'Something Went Wrong', desc: 'The request could not complete.' },
  unavailable: { glyph: '⌀', title: 'Unavailable', desc: 'This feature isn’t available right now.' },
  custom: { glyph: '★', title: 'Custom Title', desc: 'A caller-supplied icon, title, and description.' },
};

function ContentUnavailablePreview({
  variant = 'empty',
  withDescription = true,
  primaryAction = false,
  secondaryAction = false,
}: {
  variant?: keyof typeof CONTENT_UNAVAILABLE_COPY;
  withDescription?: boolean;
  primaryAction?: boolean;
  secondaryAction?: boolean;
}) {
  const copy = CONTENT_UNAVAILABLE_COPY[variant];
  if (variant === 'loading') {
    // No icon slot and no title — HermexContentUnavailable.swift's .loading variant is a plain
    // ProgressView spinner, unlike every other variant's Avatar-composed icon + title label.
    return (
      <View style={recon.cuvStack}>
        <Text style={recon.cuvSpinnerGlyph}>⟳</Text>
        {withDescription && <Text style={recon.cuvDesc}>{copy.desc}</Text>}
        <Text style={recon.note}>spinner — real animating ProgressView not reproduced</Text>
      </View>
    );
  }
  return (
    <View style={recon.cuvStack}>
      <View style={recon.cuvIconSlot}>
        <Text style={recon.cuvIconGlyph}>{copy.glyph}</Text>
      </View>
      <Text style={recon.cuvTitle}>{copy.title}</Text>
      {withDescription && <Text style={recon.cuvDesc}>{copy.desc}</Text>}
      {(primaryAction || secondaryAction) && (
        <View style={{ flexDirection: 'column', gap: 8, marginTop: 4 }}>
          {primaryAction && <Button label="Retry" variant="primary" size="small" onPress={() => {}} />}
          {secondaryAction && <Button label="Learn more" variant="tertiary" size="small" onPress={() => {}} />}
        </View>
      )}
      <Text style={recon.note}>icon slot — real SF Symbol not reproduced</Text>
    </View>
  );
}

/** The additive `.fullScreen` Layout, in a bounded phone-like frame: a reserved top spacer sized to
 *  a third of the frame's own height, so the content cluster begins ~1/3 down instead of the
 *  `.intrinsic` default's vertical centering — reconstructing HermexContentUnavailable.swift's own
 *  `GeometryReader`-based `proxy.size.height / 3` offset. */
function ContentUnavailableFullScreenPreview() {
  const copy = CONTENT_UNAVAILABLE_COPY.unavailable;
  return (
    <View style={recon.cuvFullScreenFrame}>
      <View style={recon.cuvFullScreenTopSpacer} />
      <View style={recon.cuvFullScreenContent}>
        <View style={recon.cuvIconSlot}>
          <Text style={recon.cuvIconGlyph}>{copy.glyph}</Text>
        </View>
        <Text style={recon.cuvTitle}>{copy.title}</Text>
        <Text style={recon.cuvDesc}>{copy.desc}</Text>
      </View>
      <Text style={recon.note}>.fullScreen — content begins ~1/3 down, not vertically centered</Text>
    </View>
  );
}

function CardChromePreview({
  title, footer, body, kind = 'section',
}: { title?: string; footer?: boolean; body: string; kind?: 'section' | 'request' | 'compact' | 'outlined' }) {
  const isOutlined = kind === 'outlined';
  // Issue #607 final correction pass: HermexCard.swift's surface modifiers (requestCardSurface,
  // compactCardSurface) own no title slot of their own — that belongs only to SectionCard. Reusing
  // SectionCard's uppercase caption treatment above a Request/Compact specimen implied those surfaces
  // have a title region they don't have, so a caller-supplied label on those two kinds renders as
  // ordinary content inside the surface instead, never the external SectionCard-style caption.
  const showsExternalTitle = !!title && !isOutlined && kind !== 'request' && kind !== 'compact';
  const showsInlineLabel = !!title && (kind === 'request' || kind === 'compact');
  return (
    <View>
      {showsExternalTitle && <Text style={recon.cardTitle}>{title}</Text>}
      <View style={!isOutlined && [recon.cardBox, kind === 'request' && recon.cardBoxOpaque]}>
        <Card
          density={kind === 'compact' ? 'compact' : 'default'}
          surface={isOutlined ? 'outlined' : 'elevated'}
          style={
            isOutlined
              ? [
                  recon.cardOutlinedPreview,
                  { backgroundColor: HERMEX_CARD_COLORS.primarySurface, borderColor: HERMEX_SURFACE_BORDER_COLORS.resting },
                ]
              : recon.cardTransparentSurface
          }
        >
          {showsInlineLabel && <Text style={recon.cardInlineLabel}>{title}</Text>}
          <Text style={recon.cardBody}>{body}</Text>
        </Card>
        {footer && (
          <>
            <View style={recon.cardFooterDivider} />
            <View style={recon.cardFooter}>
              <Text style={recon.cardFooterText}>Action</Text>
            </View>
          </>
        )}
      </View>
    </View>
  );
}

function IdentityAvatarPreview({ label, initials, bg, dark }: { label: string; initials: string; bg: string; dark?: boolean }) {
  return (
    <View style={[recon.avatarRow, recon.avatarIdentityItem]}>
      <View style={recon.avatarRing}>
        <Avatar initials={initials} backgroundColor={bg} size={32} accessibilityLabel={initials} />
      </View>
      <Text style={[recon.avatarLabel, dark && { color: '#ffffff', backgroundColor: '#1c1c1e', paddingHorizontal: 4, borderRadius: 4 }]}>
        {label}
      </Text>
    </View>
  );
}

// The generic catalog Avatar's own size/content API, plus the existing production identity and
// bot-face variants — kept together in one gallery (rather than a flat variants/states list) since
// the size demonstration needs its own small multi-column grid.
function AvatarFamilyGallery() {
  return (
    <View style={[recon.stack, recon.avatarGallery]}>
      <Text style={recon.caption}>Named sizes — small (32) · medium (40, default) · large (48) · one custom size</Text>
      <View style={recon.avatarPreviewRow}>
        <View style={recon.avatarCell}>
          <Avatar size="small" initials="SM" backgroundColor="#3478F6" />
          <Text style={recon.caption}>Small</Text>
        </View>
        <View style={recon.avatarCell}>
          <Avatar initials="MD" backgroundColor="#34C759" />
          <Text style={recon.caption}>Medium (default)</Text>
        </View>
        <View style={recon.avatarCell}>
          <Avatar size="large" initials="LG" backgroundColor="#8E8E93" />
          <Text style={recon.caption}>Large</Text>
        </View>
        <View style={recon.avatarCell}>
          <Avatar size={64} initials="XL" backgroundColor="#AF52DE" />
          <Text style={recon.caption}>Custom · 64</Text>
        </View>
      </View>
      <Text style={[recon.caption, { marginTop: 8 }]}>Content — Image · Icon · Initials (precedence order)</Text>
      <View style={recon.avatarPreviewRow}>
        <View style={recon.avatarCell}>
          <Avatar imageUrl="https://i.pravatar.cc/80" accessibilityLabel="Jane Appleseed" />
          <Text style={recon.caption}>Image</Text>
        </View>
        <View style={recon.avatarCell}>
          <Avatar iconName="menu" backgroundColor="#8E8E93" />
          <Text style={recon.caption}>Icon</Text>
        </View>
        <View style={recon.avatarCell}>
          <Avatar initials="JS" backgroundColor="#3478F6" />
          <Text style={recon.caption}>Initials</Text>
        </View>
      </View>
      <Text style={[recon.caption, { marginTop: 8 }]}>Production identity — ServerAvatarBadge · SessionListView inline avatar · bot face</Text>
      <View style={recon.avatarPreviewRow}>
        <IdentityAvatarPreview label="Standalone" initials="HM" bg="#3478F6" />
        <IdentityAvatarPreview label="Cross-fades to ×" initials="HM" bg="#34C759" />
        <BotMarkPreview />
      </View>
      <Text style={[recon.caption, { marginTop: 8 }]}>Fill/foreground pairing</Text>
      <View style={recon.avatarPreviewRow}>
        <IdentityAvatarPreview label="Light fill → dark foreground" initials="AB" bg="#FFD60A" />
        <IdentityAvatarPreview label="Dark fill → light foreground" initials="CD" bg="#1c1c1e" dark />
      </View>
      <Text style={[recon.caption, { marginTop: 8 }]}>System-image identity (production HermexAvatar) — used inside Content Unavailable</Text>
      <AvatarSystemImageIdentityPreview />
    </View>
  );
}

// ─── Tokens · Typography (Hermex Typography / Hermex Font) ──────────────────
const HERMES_TYPOGRAPHY_STEPS = [
  'caption / footnote / caption2',
  'captionSemibold',
  'mono12',
  'subheadline',
  'subheadlineSemibold',
  'mono14',
  'body',
  'label',
  'headline',
  'headlineSemibold',
  'title2',
  'title3',
  'title',
] as const;
type HermesTypographyStep = (typeof HERMES_TYPOGRAPHY_STEPS)[number];
const HERMES_TYPOGRAPHY_SAMPLE_STYLE: Record<HermesTypographyStep, { fontSize: number; fontWeight?: '600' | '700'; fontFamily?: string }> = {
  'caption / footnote / caption2': { fontSize: 12 },
  captionSemibold: { fontSize: 12, fontWeight: '600' },
  mono12: { fontSize: 12, fontFamily: 'Menlo' },
  subheadline: { fontSize: 14 },
  subheadlineSemibold: { fontSize: 14, fontWeight: '600' },
  mono14: { fontSize: 14, fontFamily: 'Menlo' },
  body: { fontSize: 16 },
  label: { fontSize: 16, fontWeight: '600' },
  headline: { fontSize: 18 },
  headlineSemibold: { fontSize: 18, fontWeight: '600' },
  title2: { fontSize: 22, fontWeight: '700' },
  title3: { fontSize: 20, fontWeight: '700' },
  title: { fontSize: 28, fontWeight: '700' },
};
const HERMES_TYPOGRAPHY_META: Record<HermesTypographyStep, string> = {
  'caption / footnote / caption2': '12pt regular',
  captionSemibold: '12pt semibold',
  mono12: '12pt monospaced',
  subheadline: '14pt regular',
  subheadlineSemibold: '14pt semibold',
  mono14: '14pt monospaced',
  body: '16pt regular',
  label: '16pt semibold',
  headline: '18pt regular',
  headlineSemibold: '18pt semibold',
  title2: '22pt bold',
  title3: '20pt bold',
  title: '28pt bold',
};
const HERMES_TYPOGRAPHY_USE: Record<HermesTypographyStep, string> = {
  'caption / footnote / caption2': 'Caption, footnote, and caption 2 all collapse to the same 12pt regular scale.',
  captionSemibold: 'Compact emphasized labels and statuses that need more weight than caption.',
  mono12: 'Compact counts and technical metadata where aligned digits improve scanning.',
  subheadline: 'Secondary text under a headline.',
  subheadlineSemibold: 'Selected controls and compact emphasized actions at the subheadline scale.',
  mono14: 'Code, identifiers, and technical values that need the larger compact mono size.',
  body: 'Default running/body text.',
  label: 'Compact section labels and emphasized interface labels at the same 16pt size as body.',
  headline: 'Emphasized section/row heading.',
  headlineSemibold: 'A named semibold headline for strong row and section emphasis without bold.',
  title2: 'Intentionally bold, matching title/title3\'s bold tier.',
  title3: 'Smaller page/section title.',
  title: 'Large page-level title.',
};

function HermesTypographyGallery() {
  return (
    <View style={recon.stack}>
      <Text style={recon.note}>
        Every role scales automatically with the user's Dynamic Type setting. Sizes below are React
        Native layout approximations at each role's default (non-scaled) base size, for comparison only.
      </Text>
      <TypeScaleGallery
        steps={HERMES_TYPOGRAPHY_STEPS}
        sampleStyle={(step) => HERMES_TYPOGRAPHY_SAMPLE_STYLE[step]}
        meta={(step) => HERMES_TYPOGRAPHY_META[step]}
        useNotes={HERMES_TYPOGRAPHY_USE}
      />
    </View>
  );
}

const HERMES_FONT_WEIGHT_STEPS = ['regular', 'semibold', 'bold'] as const;
type HermesFontWeightStep = (typeof HERMES_FONT_WEIGHT_STEPS)[number];
const HERMES_FONT_WEIGHT_SAMPLE_STYLE: Record<HermesFontWeightStep, { fontSize: number; fontWeight?: '600' | '700' }> = {
  regular: { fontSize: 16 },
  semibold: { fontSize: 16, fontWeight: '600' },
  bold: { fontSize: 16, fontWeight: '700' },
};
const HERMES_FONT_WEIGHT_USE: Record<HermesFontWeightStep, string> = {
  regular: 'Default weight for caption/footnote/caption2/subheadline/body/headline.',
  semibold: 'Named headline/subheadline/caption roles plus selected controls and compact emphasis.',
  bold: 'Default weight for title2/title3/title.',
};

function HermesFontGallery() {
  return (
    <DividedStack>
      <VariantGroup name="Typeface identity" desc="San Francisco (system default), plus a monospaced design for code/log content" align="left">
        <Text style={recon.note}>No custom typeface is used anywhere in this surface.</Text>
      </VariantGroup>
      <VariantGroup name="Weight scale" desc="Each role owns one fixed weight; callers choose a named role and never override weight directly" align="left">
        <TypeScaleGallery
          steps={HERMES_FONT_WEIGHT_STEPS}
          sampleStyle={(step) => HERMES_FONT_WEIGHT_SAMPLE_STYLE[step]}
          meta={(step) => (step === 'bold' ? '700' : step === 'semibold' ? '600' : '400')}
          useNotes={HERMES_FONT_WEIGHT_USE}
        />
      </VariantGroup>
    </DividedStack>
  );
}

// ─── Tokens · Colors ──────────────────────────────────────────────────────────
function HermesColorRampGallery() {
  return (
    <DividedStack gap={16}>
      <Text style={recon.caption}>{HERMES_COLOR_GENERATED_STEP_CONSUMPTION_RESTRICTION}</Text>
      {Object.keys(HERMES_COLOR_RAMPS).map((name) => (
        <VariantGroup key={name} name={name} desc="11 steps, 50–950" align="left">
          <View style={recon.row}>
            {HERMES_COLOR_RAMP_STEPS.map((step) => (
              <Swatch
                key={step}
                name={String(step)}
                value={HERMES_COLOR_RAMPS[name][step]}
                valueLabel={HERMES_COLOR_RAMPS[name][step]}
                width={100}
              />
            ))}
          </View>
        </VariantGroup>
      ))}
    </DividedStack>
  );
}

// HermesProductPalette's 6 header-accent presets and 8 project-color presets — also reused as this
// Foundations entry's own hermesReference.tokenFacts below, so the gallery and the manifest read the
// same typed values instead of a hand-maintained metadata copy.
const HERMEX_HEADER_ACCENT_PALETTE: { name: string; hex: string }[] = [
  { name: 'headerAccentYellow', hex: '#FFD700' },
  { name: 'headerAccentBlue', hex: '#5B7CFF' },
  { name: 'headerAccentPurple', hex: '#AF52DE' },
  { name: 'headerAccentRed', hex: '#FF3B30' },
  { name: 'headerAccentGreen', hex: '#34C759' },
  { name: 'headerAccentWhite', hex: '#FFFFFF' },
];
const HERMEX_PROJECT_COLOR_PALETTE: { name: string; hex: string }[] = [
  { name: 'projectSky', hex: '#7cb9ff' },
  { name: 'projectGold', hex: '#f5c542' },
  { name: 'projectRed', hex: '#e94560' },
  { name: 'projectGreen', hex: '#50c878' },
  { name: 'projectViolet', hex: '#c084fc' },
  { name: 'projectOrange', hex: '#fb923c' },
  { name: 'projectCyan', hex: '#67e8f9' },
  { name: 'projectPink', hex: '#f472b6' },
];

function HermesProductPaletteGallery() {
  const headerAccents = HERMEX_HEADER_ACCENT_PALETTE;
  const projectPalette = HERMEX_PROJECT_COLOR_PALETTE;
  return (
    <DividedStack>
      <VariantGroup name="Header accents" desc="Settings → Appearance" align="left">
        <View style={recon.row}>
          {headerAccents.map((p) => (
            <Swatch key={p.name} name={p.name} value={p.hex} valueLabel={p.hex} width={168} />
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="Project palette" desc="Sessions → Projects → New Project" align="left">
        <View style={recon.row}>
          {projectPalette.map((p) => (
            <Swatch key={p.name} name={p.name} value={p.hex} valueLabel={p.hex} width={168} />
          ))}
        </View>
      </VariantGroup>
    </DividedStack>
  );
}

function HermesColorsGallery() {
  return (
    <DividedStack>
      <VariantGroup name="Color ramps" align="left">
        <HermesColorRampGallery />
      </VariantGroup>
      <VariantGroup name="Semantic roles" align="left">
        <HermesSemanticColorReference />
      </VariantGroup>
      <VariantGroup name="Product palettes" align="left">
        <HermesProductPaletteGallery />
      </VariantGroup>
    </DividedStack>
  );
}

// ─── Tokens · Radius & Geometry ────────────────────────────────────────────────
interface GeometryFact {
  name: string;
  value: string;
  source: string;
  use: string;
}
const GEOMETRY_FACTS: GeometryFact[] = [
  { name: 'ChatComposerMetrics.cardCornerRadius', value: '26pt', source: 'HermesMobile/Features/Chat/ChatComposerPresentation.swift', use: "The composer's expanded-card corner radius." },
  { name: 'ChatComposerMetrics.actionSize', value: '44pt', source: 'HermesMobile/Features/Chat/ChatComposerPresentation.swift', use: "The round send/stop action button's diameter." },
  { name: 'ChatComposerMetrics.pillInset', value: '5pt', source: 'HermesMobile/Features/Chat/ChatComposerPresentation.swift', use: "Inset used in the collapsed pill's own corner-radius derivation." },
  { name: 'TranscriptLogRowMetrics.minimumHeight', value: '32pt', source: 'HermesMobile/Features/Chat/TranscriptLogRowView.swift', use: 'Log row height at the default text size (the real, adopted, unchanged production source — see Transcript Log Row).' },
  { name: 'TranscriptLogRowMetrics.bodyIndent', value: '26pt', source: 'HermesMobile/Features/Chat/TranscriptLogRowView.swift', use: 'Icon column width plus gap, so an expanded body indents under the row text.' },
  { name: 'TranscriptLogRowMetrics.bodyWindowHeight', value: '240pt', source: 'HermesMobile/Features/Chat/TranscriptLogRowView.swift', use: 'Fixed cap an expanded log body scrolls inside.' },
  { name: 'AdaptiveReadableContentWidth.secondaryDestination', value: '800pt', source: 'HermesMobile/Features/Shared/AdaptiveGlassModifier.swift', use: 'Max readable content width for a secondary-destination screen class.' },
  { name: 'AdaptiveReadableContentWidth.workspace', value: '1,000pt', source: 'HermesMobile/Features/Shared/AdaptiveGlassModifier.swift', use: 'Max readable content width for a workspace-class screen.' },
];

// A concise decision ladder for choosing among HermesSpacing's existing 12 steps by relationship
// and hierarchy — no new spacing values, just guidance for picking among the ones that already
// exist (HERMES_SPACING_USE above documents each individual step's own note).
interface SpacingLadderRung {
  relationship: string;
  steps: string;
  guidance: string;
}
const HERMES_SPACING_LADDER: SpacingLadderRung[] = [
  { relationship: 'Micro / inline spacing', steps: 'space.2 · space.4', guidance: 'Hairline-adjacent gaps and the tightest real gap between closely related elements, e.g. an icon and the label directly beside it.' },
  { relationship: 'Between related controls', steps: 'space.8', guidance: 'Gap between controls that read as one cluster, e.g. two buttons in the same toolbar or row.' },
  { relationship: 'Compact component padding', steps: 'space.12', guidance: 'Internal padding for a compact control, e.g. a chip, tag, or dense list row.' },
  { relationship: 'Default card / screen inset', steps: 'space.16', guidance: "A card's own padding and the standard screen horizontal inset (HermesSpacing.screenHorizontal)." },
  { relationship: 'Major content groups', steps: 'space.24', guidance: 'Gap between distinct content groups that still belong to the same screen or card.' },
  { relationship: 'Section separation', steps: 'space.32 – space.64', guidance: 'Section-to-section spacing, increasing with how distinct the sections are; values above 64 remain layout or component geometry, not the spacing scale.' },
];

const HERMES_USAGE_SIZE: GeometryFact[] = [
  { name: 'HermesUsageSize.chartHeight', value: '180pt', source: 'HermesMobile/Config/HermesSpacing.swift', use: 'Fixed plot height for active and empty Usage charts.' },
  { name: 'HermesUsageSize.legendIndicator', value: '7pt', source: 'HermesMobile/Config/HermesSpacing.swift', use: 'Diameter of each Usage chart legend color indicator.' },
  { name: 'HermesUsageSize.balanceBarHeight', value: '8pt', source: 'HermesMobile/Config/HermesSpacing.swift', use: 'Height of the provider remaining-balance bar.' },
  { name: 'HermesUsageSize.minimumBalanceFill', value: '8pt', source: 'HermesMobile/Config/HermesSpacing.swift', use: 'Minimum visible nonzero fill width in a provider balance bar.' },
];

function HermesSpacingGallery() {
  return (
    <DividedStack>
      <VariantGroup name="HermesSpacing" desc="space.0 / 2 / 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64" align="left">
        <SpacingScaleGallery steps={HERMES_SPACING_STEPS} values={HERMES_SPACING} useNotes={HERMES_SPACING_USE} />
      </VariantGroup>
      <VariantGroup name="Decision ladder" desc="Which existing step to reach for, by relationship and hierarchy — not new values." align="left">
        <View style={recon.stack}>
          {HERMES_SPACING_LADDER.map((rung, index) => (
            <TokenRow key={rung.relationship} use={rung.guidance} last={index === HERMES_SPACING_LADDER.length - 1}>
              <View style={recon.row}>
                <Text style={recon.motionName}>{rung.relationship}</Text>
                <Text style={recon.motionValue}>{rung.steps}</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="HermesUsageSize" desc="Component-scoped fixed geometry for the Usage family — not additions to the global spacing scale." align="left">
        <View style={recon.stack}>
          {HERMES_USAGE_SIZE.map((token, index) => (
            <TokenRow key={token.name} use={token.use} last={index === HERMES_USAGE_SIZE.length - 1}>
              <View style={recon.row}>
                <Text style={recon.motionName}>{token.name}</Text>
                <Text style={recon.motionValue}>{token.value}</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="Composed examples" align="left">
        <View style={recon.row}>
          <View style={spacingExample.card}>
            <Text style={spacingExample.label}>Related controls — 8 pt</Text>
            <View style={spacingExample.relatedRow}>
              <View style={spacingExample.chip} />
              <View style={spacingExample.chip} />
              <View style={spacingExample.chip} />
            </View>
          </View>
          <View style={spacingExample.card}>
            <Text style={spacingExample.label}>Separate content groups — 24 pt</Text>
            <View style={spacingExample.separateStack}>
              <View style={spacingExample.block} />
              <View style={spacingExample.block} />
            </View>
          </View>
        </View>
      </VariantGroup>
    </DividedStack>
  );
}

const spacingExample = StyleSheet.create({
  card: { width: 200, gap: 8 },
  label: { fontSize: 11, fontWeight: '700', color: '#1c1c1e' },
  relatedRow: { flexDirection: 'row', gap: 8 },
  chip: { width: 28, height: 28, borderRadius: 6, backgroundColor: '#e3e3e6' },
  separateStack: { gap: 24 },
  block: { height: 28, borderRadius: 6, backgroundColor: '#e3e3e6' },
});

// The 7-step radius scale and its semantic aliases — also reused as this Foundations entry's own
// hermesReference.tokenFacts below, so the gallery and the manifest read the same typed values.
const HERMES_RADIUS_SCALE_STEPS = [0, 4, 8, 12, 16, 20, 24] as const;
const HERMES_RADIUS_SEMANTIC_ALIASES: [string, string][] = [
  ['control', 'r8'], ['field', 'r12'], ['card', 'r16'], ['prominent', 'r20'], ['chrome', 'r24'],
];

function HermesGeometryGallery() {
  return (
    <DividedStack>
      <VariantGroup name="Reusable radius roles" desc="r0 / r4 / r8 / r12 / r16 / r20 / r24 plus control/field/card/prominent/chrome" align="left">
        <View style={recon.row}>
          {HERMES_RADIUS_SCALE_STEPS.map((step) => (
            <View key={step} style={recon.radiusCell}>
              <View style={[recon.radiusBox, { borderRadius: step }]} />
              <Text style={recon.motionValue}>r{step}</Text>
            </View>
          ))}
        </View>
        <View style={recon.radiusList}>
          {HERMES_RADIUS_SEMANTIC_ALIASES.map(([name, value], i, arr) => (
            <TokenRow key={name} use={`${name} = ${value}`} last={i === arr.length - 1}>
              <View style={recon.row}>
                <Text style={recon.motionName}>{name}</Text>
                <Text style={recon.motionValue}>{value}</Text>
              </View>
            </TokenRow>
          ))}
        </View>
        <Text style={recon.caption}>
          No .full or .pill numeric case exists — a fully-rounded edge is SwiftUI's own Capsule(),
          used directly, a platform-owned shape rather than a HermesRadius value.
        </Text>
      </VariantGroup>
      <VariantGroup name="Feature-specific geometry" desc="Named, feature-scoped constants that aren't part of the reusable radius scale" align="left">
        <View style={recon.stack}>
          {GEOMETRY_FACTS.map((fact, i) => (
            <TokenRow key={fact.name} use={fact.use} last={i === GEOMETRY_FACTS.length - 1}>
              <View style={recon.row}>
                <Text style={recon.motionName}>{fact.name}</Text>
                <Text style={recon.motionValue}>{fact.value}</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
    </DividedStack>
  );
}

// ─── Tokens · Shadow ────────────────────────────────────────────────────────
interface ShadowFact {
  name: string;
  lightOpacity: number;
  darkOpacity: number;
  radius: number;
  x: number;
  y: number;
  adaptive: boolean;
}

function ShadowCard({ fact }: { fact: ShadowFact }) {
  const [scheme, setScheme] = useState<'light' | 'dark'>('light');
  const opacity = fact.adaptive && scheme === 'dark' ? fact.darkOpacity : fact.lightOpacity;
  const cssBoxShadow = `${fact.x}px ${fact.y}px ${fact.radius}px rgba(0, 0, 0, ${fact.lightOpacity})`;
  return (
    <View style={recon.shadowCard}>
      <Text style={recon.shadowName}>{fact.name}</Text>
      <View
        style={[
          recon.shadowSwatch,
          scheme === 'dark' && recon.shadowSwatchDark,
          {
            shadowColor: '#000000',
            shadowOffset: { width: fact.x, height: fact.y },
            shadowOpacity: opacity,
            shadowRadius: fact.radius,
          },
        ]}
      />
      <Text style={recon.shadowValue}>light {fact.lightOpacity} · dark {fact.darkOpacity}</Text>
      <Text style={recon.shadowValue}>r{fact.radius} · x{fact.x} · y{fact.y}</Text>
      <Text style={recon.shadowValue}>{cssBoxShadow}</Text>
      {fact.adaptive && (
        <SegmentedToggle
          options={[
            { value: 'light', label: 'Light' },
            { value: 'dark', label: 'Dark' },
          ]}
          value={scheme}
          onChange={(value) => setScheme(value as 'light' | 'dark')}
        />
      )}
    </View>
  );
}

// The 8 HermesShadow elevation roles — also reused as this Foundations entry's own hermesReference.
// tokenFacts below, so the catalog has exactly one typed source for these values, not a gallery copy
// plus a hand-maintained metadata copy.
const HERMES_SHADOW_CASES: ShadowFact[] = [
  { name: 'none', lightOpacity: 0, darkOpacity: 0, radius: 0, x: 0, y: 0, adaptive: false },
  { name: 'controlSubtleResting', lightOpacity: 0.12, darkOpacity: 0.12, radius: 4, x: 0, y: 1, adaptive: false },
  { name: 'controlSubtlePressed', lightOpacity: 0.06, darkOpacity: 0.06, radius: 1, x: 0, y: 0, adaptive: false },
  { name: 'controlElevatedResting', lightOpacity: 0.18, darkOpacity: 0.32, radius: 16, x: 0, y: 8, adaptive: true },
  { name: 'controlElevatedPressed', lightOpacity: 0.1, darkOpacity: 0.18, radius: 8, x: 0, y: 3, adaptive: true },
  { name: 'popover', lightOpacity: 0.14, darkOpacity: 0.14, radius: 12, x: 0, y: 4, adaptive: false },
  { name: 'chrome', lightOpacity: 0.12, darkOpacity: 0.28, radius: 14, x: 0, y: 6, adaptive: true },
  { name: 'overlay', lightOpacity: 0.22, darkOpacity: 0.22, radius: 18, x: 0, y: 12, adaptive: false },
];

function HermesShadowGallery() {
  const cases: ShadowFact[] = HERMES_SHADOW_CASES;
  return (
    <DividedStack>
      <VariantGroup name="HermesShadow" desc="8 roles; resting/pressed pairs sit adjacent" align="left">
        <View style={recon.row}>
          {cases.map((fact) => (
            <ShadowCard key={fact.name} fact={fact} />
          ))}
        </View>
        <Text style={recon.note}>Approximation — native SwiftUI rendering is the source of truth.</Text>
      </VariantGroup>
    </DividedStack>
  );
}

// ─── Foundation boundary facts (overview-only) ───────────────────────────────
// These three facts describe boundaries that remain true regardless of how much of the foundation
// layer production code eventually adopts — they are not migration-count claims, and carry no totals
// or worksheet provenance. A prior version of this table also rendered a per-token-family disposition
// breakdown sourced from planning worksheets, reconciling each family's total against named
// disposition counts; that presentation was removed because it stated historical/planning figures as
// if they were the current, completed production migration or final adopted call-site population,
// which was never verified against production source at render time. Don't reintroduce a
// totals/worksheet table here.
function HermesTokenCoverageTable() {
  return (
    <DividedStack>
      <VariantGroup name="What remains true even at full adoption" align="left">
        <View style={recon.stack}>
          <Text style={recon.caption}>Hermex draws its icons from Apple's own SF Symbols, not a Hermex-authored icon library.</Text>
          <Text style={recon.caption}>No semantic surface/text/border color layer in production — SwiftUI's own semantic Color values are used directly at each call site.</Text>
          <Text style={recon.caption}>Dynamic Type owns type sizes and line heights — AppFont/.appFont(_:) supply named styles, not fixed point sizes.</Text>
        </View>
      </VariantGroup>
    </DividedStack>
  );
}

// ─── Sections ──────────────────────────────────────────────────────────────────

const ADOPTED_STATUS = 'Pre-existing production component already on master; this branch documents it without changing its implementation.';
// Truthful default for a newly added foundation component/token family with zero production call
// sites in this branch — the common case. A section only keeps ADOPTED_STATUS (above) when a real,
// grep-verified production caller exists in the current working tree.
const FOUNDATION_ONLY_STATUS = 'Available in this branch\'s foundation layer; no production call site exists yet.';

// ─── Decision-contract adoptionStatus shorthands ─────────────────────────────
// The two common cases below cover most entries; a handful of umbrella/mixed entries (Hermes
// Avatar, Hermex Colors, Hermex Iconography, Transcript Activity) write their own 'partially-
// adopted' detail inline, since their real split can't be condensed into one shared constant
// without losing which piece is which.
const FOUNDATION_AVAILABLE_ADOPTION = { state: 'foundation-available' as const, detail: FOUNDATION_ONLY_STATUS };
const PRODUCTION_ADOPTED_ADOPTION = { state: 'production-adopted' as const, detail: ADOPTED_STATUS };

export const hermesSections: SectionDef<HermesSectionId>[] = [
  {
    id: 'Hermex Typography',
    displayName: 'Typography',
    description:
      'Named text roles keep hierarchy consistent and scale with Dynamic Type. Caption, footnote, and caption 2 intentionally share the same compact base size.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesTypographyGallery />,
    hermesReference: {
      useWhen: 'Pick a named role (caption, body, headline, title, …) for any text that needs consistent hierarchy and automatic Dynamic Type scaling.',
      avoidWhen: 'Avoid hardcoding a raw font size or weight in a new screen — that bypasses Dynamic Type and this scale entirely.',
      alternatives: [],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new named-role type system; no production screen calls .appFont(_:) yet in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/AppFont.swift'],
        notes: [
          'AppFont.Role and the .appFont(_:) SwiftUI modifier (plus the equivalent UIKit resolver) are defined and unit-tested in this branch; every existing screen keeps its own current AppFont.body/.headline/.title3-style calls, unmigrated.',
          'Named emphasis roles are headlineSemibold, subheadlineSemibold, and captionSemibold; mono14 is 14pt monospaced and mono12 is 12pt monospaced.',
        ],
      },
      canonicalSymbols: ['AppFont.Role', '.appFont(_:)'],
      usageExamples: [
        { name: 'Applying a named role', language: 'swift', code: `Text("Hello")
    .appFont(.body)` },
      ],
      tokenFacts: [
        { name: 'AppFont.Role.caption / .footnote / .caption2', value: '12pt regular', purpose: 'Caption, footnote, and caption 2 all collapse to the same 12pt regular scale.' },
        { name: 'AppFont.Role.captionSemibold', value: '12pt semibold', purpose: 'Compact emphasized labels and statuses that need more weight than caption.' },
        { name: 'AppFont.Role.mono12', value: '12pt monospaced', purpose: 'Compact counts and technical metadata where aligned digits improve scanning.' },
        { name: 'AppFont.Role.subheadline', value: '14pt regular', purpose: 'Secondary text under a headline.' },
        { name: 'AppFont.Role.subheadlineSemibold', value: '14pt semibold', purpose: 'Selected controls and compact emphasized actions at the subheadline scale.' },
        { name: 'AppFont.Role.mono14', value: '14pt monospaced', purpose: 'Code, identifiers, and technical values that need the larger compact mono size.' },
        { name: 'AppFont.Role.body', value: '16pt regular', purpose: 'Default running/body text.' },
        { name: 'AppFont.Role.label', value: '16pt semibold', purpose: 'Compact section labels and emphasized interface labels at the same 16pt size as body.' },
        { name: 'AppFont.Role.headline', value: '18pt regular', purpose: 'Emphasized section/row heading.' },
        { name: 'AppFont.Role.headlineSemibold', value: '18pt semibold', purpose: 'A named semibold headline for strong row and section emphasis without bold.' },
        { name: 'AppFont.Role.title2', value: '22pt bold', purpose: 'Intentionally bold, matching title/title3\'s bold tier.' },
        { name: 'AppFont.Role.title3', value: '20pt bold', purpose: 'Smaller page/section title.' },
        { name: 'AppFont.Role.title', value: '28pt bold', purpose: 'Large page-level title.' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Font',
    displayName: 'Font',
    description:
      'Hermex uses San Francisco. Callers choose a named Hermex Typography role; the role alone decides weight and design, so a caller never passes weight or design directly.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesFontGallery />,
    hermesReference: {
      useWhen: 'Choose a Hermex Typography role and let the role decide weight and design — never pass weight or design yourself.',
      avoidWhen: 'Never pass a custom weight or design directly to .appFont(_:) — the modifier accepts neither.',
      alternatives: [
        { name: 'Hermex Typography', useWhen: 'For choosing which named role — that entry owns the selection.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A foundation-only rule on the new .appFont(_:) modifier; no production screen calls it yet in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/AppFont.swift'],
        notes: [
          '.appFont(_:) takes only a named AppFont.Role (and, on the Text overload, a required dynamicTypeSize); it accepts no weight or design arguments — the rule is enforced on the modifier\'s own signature, ahead of any screen migrating onto it. scripts/hermex_design_system_adoption_audit.py protects AppFont.swift\'s required foundation file/API snippets; it does not globally inspect or ban .appFont(_:) calls, other typography modifiers, or literal fonts across production.',
        ],
      },
      canonicalSymbols: ['AppFont.Role', '.appFont(_:)'],
      usageExamples: [
        { name: 'Role decides weight, never passed directly', language: 'swift', code: `Text("Session title")
    .appFont(.title)` },
      ],
      tokenFacts: [
        { name: 'Typeface', value: 'San Francisco (system default)', purpose: 'No custom typeface is used anywhere in this surface.' },
        { name: 'Weight · regular', value: '400', purpose: 'Default weight for caption/footnote/caption2/subheadline/body/headline.' },
        { name: 'Weight · semibold', value: '600', purpose: 'Named headline/subheadline/caption roles plus selected controls and compact emphasis.' },
        { name: 'Weight · bold', value: '700', purpose: 'Default weight for title2/title3/title.' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Adaptive Glass',
    description:
      'A shared surface treatment that uses Liquid Glass when available, Material as a fallback, and an opaque background when Reduce Transparency is enabled.',
    whenToUse: 'Use it for glass-like cards and controls instead of rebuilding platform and accessibility fallbacks on each screen.',
    props: [
      { name: 'style', type: 'AdaptiveGlassStyle', default: '.regular', desc: 'Glass style (currently only .regular exists).' },
      { name: 'isInteractive', type: 'Bool', default: 'false', desc: 'Enables Liquid Glass\'s interactive highlight response.' },
      { name: 'tint', type: 'Color?', default: 'nil', desc: 'Optional Liquid Glass tint color.' },
      { name: 'fallbackMaterial', type: 'Material', default: '.regularMaterial', desc: 'Background used on the Material path (pre-iOS 26, or Glass disabled).' },
      { name: 'inheritsClipping', type: 'Bool', default: 'false', desc: 'Forces the Material path even when Liquid Glass is available, for surfaces inside a masked/clipped ancestor.' },
      { name: 'shape', type: 'some Shape', required: true, desc: 'The shape the surface (and its stroke) is drawn into.' },
    ],
    a11y: 'The 1pt accessibility stroke is not shown by default; it appears once Reduce Transparency or Increased Contrast is on, and its opacity rises from 0.14 to 0.22 under Increased Contrast.',
    variants: {
      items: [
        { key: 'liquid', name: 'Liquid Glass · iOS 26+', node: <GlassSwatch label="Liquid Glass" style={recon.glassLiquid} /> },
        { key: 'material', name: 'Material · Fallback', node: <GlassSwatch label="Material" style={recon.glassMaterial} /> },
        { key: 'opaque', name: 'Opaque · Reduce Transparency', node: <GlassSwatch label="Opaque" style={recon.glassOpaque} /> },
      ],
    },
    states: {
      items: [
        {
          key: 'stroke-default',
          name: 'Contrast stroke · Standard',
          description: 'Shown when Reduce Transparency or Increased Contrast requires it.',
          node: <View style={[recon.strokeBox, recon.strokeThin]} />,
        },
        { key: 'stroke-increased', name: 'Contrast stroke · Increased Contrast', node: <View style={[recon.strokeBox, recon.strokeThick]} /> },
        { key: 'non-interactive', name: 'Non-interactive · Default', node: <GlassSwatch label="Static surface" style={recon.glassLiquid} /> },
        { key: 'interactive', name: 'Interactive · isInteractive', node: <GlassSwatch label="Highlight on touch" style={recon.glassLiquid} /> },
        {
          key: 'clipped-ancestor',
          name: 'Clipped ancestor',
          description: 'Clipped-ancestor fallback when inheritsClipping is true.',
          node: <GlassSwatch label="Forces Material" style={recon.glassMaterial} />,
        },
      ],
    },
    hermesReference: {
      useWhen: 'Use it for glass-like cards and controls instead of rebuilding platform and accessibility fallbacks on each screen.',
      avoidWhen: 'Avoid it when a surface must stay unconditionally opaque regardless of Liquid Glass availability — an approval/clarification surface that must always read clearly over live transcript text.',
      alternatives: [
        { name: 'Pending Request', useWhen: 'For an approval/clarification surface that must stay unconditionally opaque over live transcript text — its adopted pendingRequestCardSurface, not a glass fallback.' },
        { name: 'Hermes Card', useWhen: 'For the .outlined surface only — a flat system-background card with a separator border and no glass.' },
      ],
      adoptionStatus: PRODUCTION_ADOPTED_ADOPTION,
      usedIn: [
        { screen: 'Settings', effect: 'Grouped settings cards use the shared glass treatment.' },
        { screen: 'Tasks', path: 'Tasks → open a task', effect: 'Section cards use the shared surface treatment.' },
        { screen: 'Usage', effect: 'Totals, charts, and provider-limit cards use the same card foundation.' },
      ],
      implementationNotes: {
        status: ADOPTED_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/AdaptiveGlassModifier.swift', 'HermesMobileTests/AdaptiveGlassTests.swift'],
        notes: [
          'Rendered evidence comes from a captured iPhone 17 Pro simulator run (iOS 26.5, light appearance); the Liquid Glass branch itself is not independently confirmed by that capture.',
        ],
      },
      canonicalSymbols: ['.adaptiveGlass(_:isInteractive:tint:fallbackMaterial:inheritsClipping:in:)', 'AdaptiveGlassStyle'],
      usageExamples: [
        { name: 'Applying the glass surface to a card', language: 'swift', code: `SomeCardContent()
    .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: HermesRadius.card))` },
      ],
      compositionSlots: [
        {
          name: 'content', description: 'The view the Adaptive Glass surface treatment is applied to.', cardinality: 'one', acceptedContent: ['generic-view'],
          order: 0, role: 'body-content',
          layout: { placement: 'caller-ordered', axis: 'none', position: "fills the modifier's host view" },
          overflow: 'clip', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Card',
    displayName: 'Card',
    description:
      'HermexCard.swift is a new, foundation-only Card primitive in this branch — not a constructible view, but a surface-modifier family: View modifiers (.hermexCardSurface(_:cornerRadius:), .compactCardSurface(cornerRadius:fill:), .requestCardSurface(cornerRadius:material:)) plus shared HermexCardMetrics/HermexCardColors constants, applying canonical chrome (corner radius, background, border — no shadow/elevation) to caller-owned content behind four conceptual surfaces: default/glass, Outlined, Request, and Compact. It does not replace or share an implementation with the existing, already-adopted SectionCard.swift, which remains its own separate, unmodified production component — with its own real title/content/footer anatomy — in this slice. The adopted Pending Request approval/clarification surface likewise uses its own separate, pre-existing .pendingRequestCardSurface(cornerRadius:) implementation (PendingRequestSurfaces.swift), not this family\'s own .requestCardSurface.',
    whenToUse: 'Reach for the default surface (.hermexCardSurface(.glass)) for grouped content, .hermexCardSurface(.outlined) for a quiet system-background surface with a separator border, and .compactCardSurface only where a component composition documents the reduced density — never as a silent caller-side padding override. For an approval/clarification surface, use the Pending Request pattern.',
    props: [
      { name: '.hermexCardSurface(_:cornerRadius:)', type: '(HermexCardSurface, cornerRadius: CGFloat = HermesRadius.card) -> some View', desc: 'Defaults to adaptive glass (.glass). Outlined (.outlined) is the canonical outlined Card treatment: semantic system background, 1pt separator-grey border, and no elevation — resolved through HermexCardColors.primarySurface and the shared HermexSurfaceBorderColors.resting / .increasedContrast (not a HermexCardColors-owned border, and never a raw platform color). Applied directly to caller-owned content — HermexCard.swift declares no title/content/footer view of its own.' },
      { name: '.compactCardSurface(cornerRadius:fill:)', type: '(cornerRadius: CGFloat = HermesRadius.card, fill: Color = HermexCardColors.secondarySurface) -> some View', desc: 'The explicit, named compact-density surface for component compositions such as normal Attachment tiles — not Card\'s 16pt default, and never a silent caller-side padding override.' },
      { name: '.requestCardSurface(cornerRadius:material:)', type: '(cornerRadius: CGFloat, material: RequestCardMaterial = .opaque) -> some View', desc: 'The opaque approval/clarification surface this family defines. .translucentOverScrim is the one documented exception, for a card that sits over its own dimmed scrim. Has no caller in this branch — the adopted Pending Request surface uses the separate .pendingRequestCardSurface(cornerRadius:) instead.' },
      { name: 'HermexCardMetrics.contentPadding', type: 'CGFloat', default: 'HermesSpacing.s16 (16)', desc: 'The shared 16pt content padding on every edge a caller applies to its own content with its own .padding(...) before calling a surface modifier (see the usage example below) — the modifiers themselves add no padding.' },
      { name: 'HermexCardColors', type: 'enum (Color)', desc: 'primarySurface / secondarySurface — the two surface fills every variant\'s background resolves to. HermexCardColors declares no border color of its own; every variant\'s border instead resolves to the shared HermexSurfaceBorderColors.' },
    ],
    a11y: 'HermexCard.swift\'s surface modifiers add no accessibility grouping of their own — a caller\'s existing content keeps whatever accessibility structure it already has. SectionCard (a separate, pre-existing component) relies on the default per-child announcement order of its own VStack.',
    variants: {
      itemsFill: true,
      align: 'left',
      items: [
        { key: 'section-with-title', name: 'Section Card — with title', node: <CardChromePreview title="USAGE" body="128 requests today" /> },
        { key: 'section-no-title', name: 'Section Card — no title', node: <CardChromePreview body="128 requests today" /> },
        { key: 'outlined-card', name: 'Outlined Card — white with grey border', node: <CardChromePreview body="Enjoying Hermex?" kind="outlined" /> },
        { key: 'request-card', name: 'Request Card — opaque approval surface', node: <CardChromePreview title="CLARIFICATION" body="Which branch should this target?" kind="request" /> },
        { key: 'compact-card', name: 'Compact Card — explicit compact density', node: <CardChromePreview title="COMPACT" body="Reduced (not 16pt) padding" kind="compact" /> },
        { key: 'settings-required-title', name: 'SettingsCard — required title (private)', node: <CardChromePreview title="APPEARANCE" body="Header logo color" /> },
      ],
    },
    states: {
      itemsFill: true,
      align: 'left',
      items: [
        { key: 'with-footer', name: 'Section Card — with footer', node: <CardChromePreview title="TASK" body="Run tests before merge" footer /> },
        { key: 'no-footer', name: 'Section Card — no footer', node: <CardChromePreview title="TASK" body="Run tests before merge" /> },
      ],
    },
    hermesReference: {
      useWhen: 'Reach for the default surface (.hermexCardSurface(.glass)) for grouped content, .hermexCardSurface(.outlined) for a quiet system-background surface with a separator border, and .compactCardSurface only where a component composition documents the reduced density. For an approval/clarification surface, use the Pending Request pattern.',
      avoidWhen: 'Avoid HermexCard.swift on a production screen today — no screen imports it yet; reach for the existing, already-adopted SectionCard/SettingsCard instead. Never use .compactCardSurface as a silent caller-side padding override.',
      alternatives: [
        { name: 'SectionCard / SettingsCard (production)', useWhen: 'For any current production screen — these pre-existing components (with their own real title/content/footer anatomy) are what developers actually reach for today.' },
        { name: 'Pending Request', useWhen: 'For any approval/clarification surface over live transcript text — pendingRequestCardSurface is the adopted implementation; HermexCard\'s own .requestCardSurface has no caller.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'HermexCard.swift itself has no production call site in this branch. SectionCard.swift — a separate, pre-existing, already-adopted component with its own implementation (and its own real title/content/footer anatomy) — is the one production developers actually reach for today; it is documented here as the closest production analog, not as a HermexCard.swift caller.',
      usedIn: [],
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/HermexCard.swift', 'HermesMobile/Features/Shared/HermexSurfaceBorder.swift'],
        notes: [
          'HermexCard.swift\'s canonical chrome is a family of View modifiers, not a view with its own content anatomy: .hermexCardSurface(_:cornerRadius:) resolves HermexCardSurface.glass to an adaptive-glass background plus a hairline border, and .outlined to an opaque background plus a 1pt border; .compactCardSurface(cornerRadius:fill:) is the separate, explicitly compact-density surface for component compositions such as normal Attachment tiles — not Card\'s 16pt default; .requestCardSurface(cornerRadius:material:) is the opaque approval/clarification surface Request Card describes, with .translucentOverScrim the one documented exception for a card over its own dimmed scrim. Every variant\'s background resolves to HermexCardColors.primarySurface or .secondarySurface (never a platform color), and every variant\'s border resolves to the shared HermexSurfaceBorderColors.resting or HermexSurfaceBorderColors.increasedContrast — HermexCardColors itself declares no border color. None of these modifiers add a shadow; .hermexCardSurface applies no elevation. HermexCardMetrics.contentPadding (HermesSpacing.s16) is a caller-owned constant applied with the caller\'s own .padding(...) before the surface modifier runs (see the usage example below) — the modifiers themselves add no padding.',
          'HermexSurfaceBorderColors.resting is Neutral.adaptive(light: Neutral.s600 / #808084, dark: Neutral.s400 / #AEAEB1); .increasedContrast is Neutral.adaptive(light: Neutral.s800 / #58585B, dark: Neutral.s200 / #DFDFE1). This static web catalog renders only the light .resting anchor (Neutral[600]) on its default specimens; the remaining anchors above are documented here, not rendered. A pure hex contrast-ratio calculation (not a visual-only pass) confirms both the resting and increasedContrast anchors are >=3:1 against the primary and secondary Card surfaces in their respective appearance, per hermes-catalog.test.mjs.',
          'SectionCard.swift and SettingsCard (both pre-existing, unmodified, and genuinely used at the screens listed above) implement their own chrome, and their own real title/content/footer anatomy, independently — this branch does not change them to delegate to HermexCard.swift, and no production file imports HermexCard.swift. HermexCard.swift itself owns no title or footer slot; those belong to SectionCard/SettingsCard, not to this surface-modifier family.',
          'Pending-request fields, choices, command blocks, decision logic, and request lifecycle stay part of the Pending Request pattern, which also does not depend on HermexCard.swift — see that entry\'s own corrected sourcePaths.',
        ],
      },
      canonicalSymbols: ['.hermexCardSurface(_:cornerRadius:)', 'HermexCardSurface', '.compactCardSurface(cornerRadius:fill:)', '.requestCardSurface(cornerRadius:material:)', 'RequestCardMaterial', 'HermexCardMetrics', 'HermexCardColors'],
      usageExamples: [
        { name: 'Outlined Card surface applied to content', language: 'swift', code: `VStack(alignment: .leading) {
    Text("USAGE")
    Text("128 requests today")
}
.padding(HermexCardMetrics.contentPadding)
.hermexCardSurface(.outlined)` },
      ],
      compositionSlots: [
        {
          name: 'content', description: 'The caller-owned content a surface modifier is applied to. HermexCard.swift\'s modifiers wrap existing content and own no title/footer anatomy of their own; a caller applies HermexCardMetrics.contentPadding itself where the 16pt default is wanted.', required: true, cardinality: 'one', acceptedContent: ['generic-view'],
          order: 0, role: 'surface-content',
          layout: { placement: 'component-fixed', axis: 'none', position: 'wherever the caller composes it; the modifier adds no layout of its own' },
          overflow: 'wrap', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Attachment',
    description:
      'A new, foundation-only component family — not a Pattern, not a Card variant — for message, composer, and compact-preview file attachments, plus a file-type fallback. AttachmentFileType owns the icon/tint/label mapping shared across every variant. Colors reference the Hermex color ramps and fixed component geometry references the HermesAttachmentSize scale (both documented below), but this whole family has no production call site yet — production\'s existing attachment tiles keep their own independent implementation.',
    whenToUse: 'Use it for any surface that shows a file attachment; use the compact preview specifically for a 30×30 inline thumbnail, not the full tile.',
    props: [
      { name: 'iconName', type: 'String', desc: 'SF Symbol for the file\'s extension — tablecells, doc.text, doc.richtext, archivebox, or a doc fallback. AttachmentFileGlyph takes a caller-supplied size; AttachmentFileBadge renders it at HermesIconSize.large inside the icon panel.' },
      { name: 'tintColor', type: 'Color', desc: 'File-color mapping onto the (foundation-only) Hermex color ramps: spreadsheet → Green 500, text-like → Blue 500, PDF → Red 500, archive → Orange 500, unknown/default → Neutral 500.' },
      { name: 'extensionLabel', type: 'String', desc: 'Uppercased extension, truncated to 5 characters, or "FILE" when there is none.' },
      {
        name: 'HermesAttachmentSize',
        type: 'enum (CGFloat)',
        desc: `Fixed component geometry — not a spacing/radius token: HERMES_ATTACHMENT_SIZE.compactPreview (${HERMES_ATTACHMENT_SIZE.compactPreview}), HERMES_ATTACHMENT_SIZE.messageGridCell (${HERMES_ATTACHMENT_SIZE.messageGridCell}), HERMES_ATTACHMENT_SIZE.composerImage (${HERMES_ATTACHMENT_SIZE.composerImage}; HERMES_ATTACHMENT_SIZE.composerImageAccessibility ${HERMES_ATTACHMENT_SIZE.composerImageAccessibility}), HERMES_ATTACHMENT_SIZE.fileIconPanelWidth × HERMES_ATTACHMENT_SIZE.fileIconPanelHeight (${HERMES_ATTACHMENT_SIZE.fileIconPanelWidth}×${HERMES_ATTACHMENT_SIZE.fileIconPanelHeight}; HERMES_ATTACHMENT_SIZE.fileIconPanelWidthAccessibility × HERMES_ATTACHMENT_SIZE.fileIconPanelHeightAccessibility ${HERMES_ATTACHMENT_SIZE.fileIconPanelWidthAccessibility}×${HERMES_ATTACHMENT_SIZE.fileIconPanelHeightAccessibility}), HERMES_ATTACHMENT_SIZE.composerFileTextWidth (${HERMES_ATTACHMENT_SIZE.composerFileTextWidth}; HERMES_ATTACHMENT_SIZE.composerFileTextWidthAccessibility ${HERMES_ATTACHMENT_SIZE.composerFileTextWidthAccessibility}), HERMES_ATTACHMENT_SIZE.composerFileTileWidth (${HERMES_ATTACHMENT_SIZE.composerFileTileWidth}; HERMES_ATTACHMENT_SIZE.composerFileTileWidthAccessibility ${HERMES_ATTACHMENT_SIZE.composerFileTileWidthAccessibility}) × HERMES_ATTACHMENT_SIZE.composerFileTileMinHeight (${HERMES_ATTACHMENT_SIZE.composerFileTileMinHeight}; HERMES_ATTACHMENT_SIZE.composerFileTileMinHeightAccessibility ${HERMES_ATTACHMENT_SIZE.composerFileTileMinHeightAccessibility}), HERMES_ATTACHMENT_SIZE.composerStripHeight (${HERMES_ATTACHMENT_SIZE.composerStripHeight}; HERMES_ATTACHMENT_SIZE.composerStripHeightAccessibility ${HERMES_ATTACHMENT_SIZE.composerStripHeightAccessibility}), HERMES_ATTACHMENT_SIZE.messageFileTextInset (${HERMES_ATTACHMENT_SIZE.messageFileTextInset}), HERMES_ATTACHMENT_SIZE.removeControl (${HERMES_ATTACHMENT_SIZE.removeControl}), HERMES_ATTACHMENT_SIZE.removeOverlap (${HERMES_ATTACHMENT_SIZE.removeOverlap}), HERMES_ATTACHMENT_SIZE.accessibilityVerticalPadding (${HERMES_ATTACHMENT_SIZE.accessibilityVerticalPadding}). This is a fixed, Attachment-only set of named component dimensions, no new global spacing or radius scale.`,
      },
      {
        name: 'HermesIconSize.large',
        type: 'CGFloat',
        desc: `HERMES_ICON_SIZE.large (${HERMES_ICON_SIZE.large}) — the file-type glyph size AttachmentFileBadge uses inside its icon panel. A separate, foundation-only icon-size family; no new color family.`,
      },
    ],
    a11y: 'Each tile is one combined accessibility element (children: .ignore) with a label naming the attachment and its type/detail/state (e.g. upload failure). The full-box loading Skeleton stands in for indefinite loading only — never a measurable upload percentage, which the production tile shows separately via its own progress UI.',
    render: () => <AttachmentTileGallery />,
    hermesReference: {
      useWhen: 'Use it for any surface that shows a file attachment; use the compact preview specifically for a 30×30 inline thumbnail, not the full tile.',
      avoidWhen: 'Avoid composing it on a production screen today — the existing message/composer attachment tiles keep their own separate, unmigrated implementation.',
      alternatives: [
        { name: 'MessageBubbleView / ChatComposerAttachmentStripView (production)', useWhen: 'For any current production attachment surface — this family has no production call site yet.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only component family; production\'s message and composer attachment tiles (MessageBubbleView.swift, ChatComposerAttachmentStripView.swift) keep their own existing, unmigrated implementation in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/AttachmentFileType.swift',
          'HermesMobile/Features/Shared/AttachmentTile.swift',
        ],
        notes: [
          'AttachmentFileType\'s extension→icon/color mapping and AttachmentImageTileSurface\'s Compact Card composed surface are defined and unit-tested here; MessageBubbleView.swift and ChatComposerAttachmentStripView.swift do not import either file in this branch.',
          'Underneath these Hermex compositions, native SwiftUI primitives (Image, Text, ProgressView) remain the actual rendering primitives — Card, Button, Icon, and Skeleton compose them, they do not replace them.',
        ],
      },
      canonicalSymbols: ['AttachmentFileType', 'AttachmentFileBadge', 'AttachmentFileGlyph', 'AttachmentImageTileSurface'],
      usageExamples: [
        { name: 'Rendering a spreadsheet file badge', language: 'swift', code: `let fileType = AttachmentFileType(fileName: "Q3-actuals.xlsx")
AttachmentFileBadge(
    fileType: fileType,
    width: HermesAttachmentSize.fileIconPanelWidth,
    height: HermesAttachmentSize.fileIconPanelHeight
)` },
      ],
      machineConfigurations: [
        { name: 'Compact preview', description: '30x30 inline thumbnail.', props: { size: 'HERMES_ATTACHMENT_SIZE.compactPreview' } },
        { name: 'Message grid cell', props: { size: 'HERMES_ATTACHMENT_SIZE.messageGridCell' } },
        { name: 'Composer image tile', props: { size: 'HERMES_ATTACHMENT_SIZE.composerImage' } },
        { name: 'File icon panel', props: { size: 'HERMES_ATTACHMENT_SIZE.fileIconPanelWidth x HERMES_ATTACHMENT_SIZE.fileIconPanelHeight' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Banner',
    displayName: 'Banner',
    description:
      'A separate component family for persistent in-flow status communication — Information, Warning, Error, Success, and Offline variants, each with an independently caller-optional title and description (at least one is required), an optional icon, an optional action, inset or full-width presentation, and consistent decorative-icon accessibility. The native HermexBanner (HermesMobile/Features/Shared/HermexBanner.swift) has no interactive show/hide state — a caller that only has one line of copy simply omits the other region, it does not toggle anything at runtime.',
    whenToUse: 'Use an in-flow Banner rather than a toast when the condition remains relevant until it is resolved (e.g. offline, a pending update) rather than a one-off confirmation.',
    props: [
      { name: 'semantic (native) / variant (catalog reconstruction)', type: "HermexBanner.Semantic / 'info' | 'warning' | 'negative' | 'positive' | 'neutral'", default: ".warning / 'warning'", desc: 'Native Information / Warning / Error / Success / Offline map to .information/.warning/.error/.success/.offline. The React Native documentation reconstruction uses info/warning/negative/positive; its Offline specimen approximates the native orange wifi.slash treatment with disclosed warning styling and the closest available icon.' },
      { name: 'title', type: 'string (optional)', desc: 'Independently caller-optional on the native HermexBanner (title: Text?) — the stronger tier when both title and description are present. Omit it entirely for a description-only composition; there is no interactive way to hide it, only caller omission.' },
      { name: 'description', type: 'string (optional)', desc: 'Independently caller-optional on the native HermexBanner (description: Text?) — the quieter, multiline tier when a title is also present, or full readable-emphasis text when it is the only content. At least one of title/description is required.' },
      { name: 'icon', type: 'IconName', desc: 'Optional leading icon override — decorative by default (hidden from VoiceOver) unless it carries information the title text does not. The native showsIcon: Bool lets a caller hide the icon entirely.' },
      { name: 'action', type: '{ label: string; onPress: () => void }', desc: 'Optional trailing action button. The native HermexBanner.Action also supports an icon-only action with its own accessibility label.' },
      { name: 'style (inset padding)', type: 'ViewStyle', desc: 'Caller-supplied horizontal padding for an inset presentation; omit it for full-width/edge-to-edge.' },
    ],
    a11y: 'A decorative status icon is hidden from VoiceOver by default, since the surrounding title text already announces the same fact.',
    render: () => <BannerFamilyGallery />,
    hermesReference: {
      useWhen: 'Use an in-flow Banner rather than a toast when the condition remains relevant until it is resolved (e.g. offline, a pending update) rather than a one-off confirmation.',
      avoidWhen: 'Avoid it for a one-off confirmation — use Hermes Toast for a transient message instead.',
      alternatives: [
        { name: 'Hermes Toast', useWhen: 'For a transient, one-off confirmation the caller dismisses itself (HermexToast has no auto-dismiss timer) rather than a persistent in-flow condition.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new foundation/catalog component with zero production call sites in this branch. The composer-style error specimen demonstrates valid description-only inset composition without claiming adoption. ChatView.swift, SessionListView.swift, and every composer keep their existing production status surfaces.',
      implementationNotes: {
        status: 'Foundation-only with zero production adoption; the native API, tests, DEBUG fixtures, and catalog reconstruction are available for future callers.',
        sourcePaths: [
          'HermesMobile/Features/Shared/HermexBanner.swift',
        ],
        notes: [
          'ChatView.swift and SessionListView.swift each still implement their own offline-cache notice independently in this branch — a future HermexBanner.offlineCache() consolidation, described here as a foundation capability, has not been made against either call site.',
          'ChatComposerView.swift, BotChatComposerView.swift, and BotRoomComposerView.swift retain their existing status surfaces; none calls HermexBanner( in this branch.',
          `The inline icon renders at HermesIconSize.small (${HERMES_ICON_SIZE.small}) — a size choice this component makes, not a fact about either existing offline-cache notice.`,
          'This native/components/Banner/Banner.tsx is a React Native documentation reconstruction of the native HermexBanner.swift above, not the production component itself — Issue #607 corrected its standard layout so a description-only composition renders the description in the header row beside the icon, rather than an icon-only header plus an indented second row.',
        ],
      },
      canonicalSymbols: ['HermexBanner', 'HermexBanner.Action'],
      usageExamples: [
        { name: 'Description-only inset banner', language: 'swift', code: `HermexBanner(
    .offline,
    description: Text("You're offline. Showing cached data."),
    showsIcon: true,
    presentation: .inset
)` },
      ],
      machineConfigurations: [
        { name: 'Information', props: { semantic: '.information', reconstructionVariant: 'info' } },
        { name: 'Warning', props: { semantic: '.warning', reconstructionVariant: 'warning' } },
        { name: 'Error', props: { semantic: '.error', reconstructionVariant: 'negative' } },
        { name: 'Success', props: { semantic: '.success', reconstructionVariant: 'positive' } },
        { name: 'Offline', props: { semantic: '.offline', reconstructionVariant: 'warning', reconstructionIcon: 'triangle-alert (closest available stand-in for wifi.slash)' } },
      ],
      compositionSlots: [
        {
          name: 'icon', description: 'Optional leading status icon — decorative by default, hidden from VoiceOver unless it carries information the title/description text does not.', cardinality: 'one', acceptedContent: ['icon'],
          order: 0, role: 'leading-icon',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge of the header row' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'title', description: 'The stronger-emphasis text region when both title and description are present, or the sole text when description is absent.', cardinality: 'one', acceptedContent: ['text'],
          order: 1, role: 'primary-text',
          layout: { placement: 'component-fixed', axis: 'none', position: 'header row, beside the icon' },
          overflow: 'wrap', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'description', description: 'The quieter, multiline text region when a title is also present, or full readable-emphasis text occupying the primary text position when it is the only content.', cardinality: 'one', acceptedContent: ['text'],
          order: 2, role: 'secondary-text',
          layout: { placement: 'component-fixed', axis: 'none', position: 'below title, or the header row when title is absent' },
          overflow: 'wrap', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'action', description: 'Optional trailing action — a text button or an icon-only action, each with its own accessibility label.', cardinality: 'one', acceptedContent: ['control'],
          order: 3, role: 'trailing-action',
          layout: { placement: 'component-fixed', axis: 'none', position: 'trailing edge' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [
        { kind: 'at-least-one-of', slots: ['title', 'description'], detail: 'A HermexBanner must supply a title, a description, or both — never neither, guarded by a debug/runtime precondition.' },
      ],
    },
  },
  {
    id: 'Hermes Avatar',
    displayName: 'Avatar',
    description:
      'Colored initials identify the active server or account. In the Sessions header, the same control changes into a close button while search is open.',
    props: [
      { name: 'initials', type: 'String', required: true, desc: 'Displayed initials (production Swift).' },
      { name: 'colorHex / selectedHeaderLogoColor', type: 'String / Color', required: true, desc: 'Per-server or per-account Header Logo Color fill (production Swift).' },
      { name: 'size (ServerAvatarBadge, production Swift)', type: 'CGFloat', default: '32', desc: 'ServerAvatarBadge only — the inline header avatar uses a fixed search-chrome icon size instead.' },
      { name: 'HermesAvatarSize (production Swift)', type: '.small (32) | .medium (40) | .large (48)', default: '.medium', desc: 'Named diameter token for Avatar compositions. Foundation-only: it is read only by other new foundation files (AccordionList\'s leading-slot inset and HermexAvatar\'s diameter) — no production screen uses it; the composed specimens live in the DEBUG-only HermexOverlayLab.' },
      { name: 'systemImage (HermexAvatar, production Swift)', type: 'String', required: true, desc: 'An SF Symbol name, sized to HermesIconSize.Avatar at the chosen HermesAvatarSize.' },
      { name: 'isDecorative (HermexAvatar, production Swift)', type: 'Bool', default: 'true', desc: 'Hides the badge from VoiceOver when the surrounding content already names the identity, matching Content Unavailable\'s own combined accessibility element.' },
      {
        name: 'size (generic catalog Avatar)',
        type: "'small' (32) | 'medium' (40, default) | 'large' (48) | number",
        default: "'medium'",
        desc: 'Named steps from the exported, immutable AVATAR_SIZE map cover the common cases; pass a raw number as an intentional custom-size escape hatch (e.g. a larger hero avatar) when no named step fits.',
      },
    ],
    a11y: 'ServerAvatarBadge is hidden from VoiceOver — the row around it supplies the accessible name instead. The inline Sessions header version shares the enclosing button\'s label. BotInteractiveFaceView is also hidden from VoiceOver — it is a decorative, non-content-bearing hero illustration. HermexAvatar defaults to decorative, matching Content Unavailable\'s combined title+icon element. The generic catalog Avatar exposes accessibilityRole="image" with a label (defaulting to its initials).',
    render: () => <AvatarFamilyGallery />,
    hermesReference: {
      useWhen: 'For an initials identity, production has no shared component yet: ServerAvatarBadge is private to Settings, and the Sessions header and Identity editor each draw their own inline circle; use HermexAvatar for a circular SF Symbol identity badge at a named HermesAvatarSize, such as the glyph inside an empty or error state; use the bot-face system only for the Bots hero/idle face. HermexAvatar takes a system image only — it has no photo or initials mode.',
      avoidWhen: 'Avoid the new HermexAvatar.swift system-image badge as a production dependency today — no screen composes it yet. Avoid reaching for the bot-face system outside Bots — it is a separate drawing/motion system, not a general-purpose Avatar.',
      alternatives: [
        { name: 'Content Unavailable', useWhen: 'When an identity-style icon badge belongs inside an empty/error state rather than standing alone — Content Unavailable already composes an Avatar-style icon slot for that.' },
      ],
      adoptionStatus: {
        state: 'partially-adopted',
        detail: 'ServerAvatarBadge and the bot-face system are adopted, pre-existing production components, unchanged by this branch. HermexAvatar.swift and HermesAvatarSize are new in this branch\'s foundation layer, with no production call site yet.',
      },
      useSummary: 'Two separate stories under one umbrella section: ServerAvatarBadge and the bot-face system are pre-existing, unchanged production identity components; HermexAvatar.swift and HermesAvatarSize are new in this branch, with no production call site yet.',
      usedIn: [
        { screen: 'Sessions', effect: 'The pre-existing inline header avatar (drawn directly in SessionListView, not ServerAvatarBadge) opens account and server controls; it becomes the search-close control when needed.' },
        { screen: 'Servers', path: 'Settings → Servers', effect: 'The pre-existing ServerAvatarBadge gives each configured server an initials badge in the server list and the server editor.' },
        { screen: 'Identity', path: 'Settings → Identity', effect: 'The pre-existing Sessions Avatar editor previews the selected initials and header color with its own inline circle.' },
        { screen: 'Bots', effect: 'The pre-existing bot-face system blinks idly (BotAnimatedFaceView) and reacts to a drag/tap on its create/edit hero face (BotInteractiveFaceView) — a separately implemented system, unrelated to the new HermexAvatar.swift.' },
      ],
      implementationNotes: {
        status: 'ServerAvatarBadge and the bot-face system: adopted, pre-existing production components, unchanged by this branch. HermexAvatar.swift and HermesAvatarSize: new in this branch\'s foundation layer, with no production call site yet.',
        sourcePaths: [
          'HermesMobile/Features/Settings/SettingsView.swift',
          'HermesMobile/Features/Bots/BotAvatarStore.swift',
          'HermesMobile/Features/Bots/BotProfileAppearance.swift',
          'HermesMobile/Features/Bots/BotFaceMotion.swift',
          'HermesMobile/Features/Shared/HermexAvatar.swift',
          'HermesMobile/Config/HermesSpacing.swift',
        ],
        notes: [
          'HermesAvatarSize is defined in HermesMobile/Config/HermesSpacing.swift, not in the pre-existing bot-appearance files — those files implement their own, separately-scaled identity system and do not reference HermesAvatarSize.',
          'One umbrella documentation section for image/icon/initials identity and bot-face identity, but not one shared implementation: BotAvatarMarkView (still), BotAnimatedFaceView (idle blink + working, Reduce Motion falls back to still), and BotInteractiveFaceView (hero drag-to-gaze/tap-to-react face) stay their own pre-existing SwiftUI types — bot faces are a distinct drawing/motion system, never adopting the umbrella Avatar family described here.',
          'HermexAvatar.swift is the new foundation piece: a circular system-image badge at HermesAvatarSize, intended so a future Content Unavailable-style empty state could stop hand-rolling a raw Label icon treatment — it has not replaced ServerAvatarBadge or the bot-face system, and no production caller composes it yet.',
        ],
      },
      canonicalSymbols: ['HermexAvatar', 'HermesAvatarSize'],
      usageExamples: [
        { name: 'System-image badge at a named size', language: 'swift', code: `HermexAvatar(systemImage: "person.fill", size: .medium)` },
      ],
      machineConfigurations: [
        { name: 'Small', props: { size: '.small', diameter: 32 } },
        { name: 'Medium', props: { size: '.medium', diameter: 40 } },
        { name: 'Large', props: { size: '.large', diameter: 48 } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Row Divider',
    description:
      'HermexDivider is the shared SwiftUI hairline separator: it derives color from primary at 0.12 opacity, resolves one physical pixel from displayScale, accepts a tokenized leading inset, and is hidden from accessibility. The generic catalog Divider is the React Native documentation counterpart with component-owned opacity.',
    whenToUse: 'Use it between rows or under a card footer — never inside a native List, HermexList, or Accordion List, which already own their separators; do not invent a second, differently-styled divider for a new screen.',
    props: [
      { name: 'HermexDivider', type: 'View', desc: 'Shared SwiftUI divider with background-agnostic foreground-derived color and one-physical-pixel geometry.' },
      { name: 'leadingInset', type: 'CGFloat', default: 'HermesSpacing.s0', desc: 'Tokenized leading inset for row-aligned separators.' },
      { name: 'opacity (generic catalog Divider)', type: 'number', default: '0.72', desc: 'The RN reference component\'s own component-owned opacity prop, translucent by default; pass 1 for full strength (Card\'s footer divider).' },
    ],
    a11y: 'Purely decorative — HermexDivider explicitly hides itself from accessibility.',
    render: () => <HermexDividerPreview />,
    hermesReference: {
      useWhen: 'Use it between rows or under a card footer.',
      avoidWhen: 'Avoid it inside a native List, HermexList, or Accordion List — those containers draw their own separators. Do not invent a second, differently-styled divider for a new screen.',
      alternatives: [
        { name: 'List / ListItem', useWhen: 'For rows inside a List container, which owns the separators.' },
        { name: 'Native Divider (production)', useWhen: 'For current Settings groups and the SectionCard footer, which keep the native hairline today.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only component; Settings and SectionCard\'s footer keep their own existing native Divider/hairline styling in this branch, not HermexDivider.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/HermexDivider.swift'],
        notes: [
          'HermexDivider owns its SwiftUI opacity and pixel geometry; callers choose only the tokenized leading inset. No global free-floating opacity token is exposed.',
          'The generic catalog Divider owns opacity as an explicit component prop for its React Native reconstruction; callers do not apply external opacity styles.',
        ],
      },
      canonicalSymbols: ['HermexDivider'],
      usageExamples: [
        { name: 'Row-aligned divider with a tokenized inset', language: 'swift', code: `HermexDivider(leadingInset: HermesSpacing.s16)` },
      ],
      machineConfigurations: [
        { name: 'Default inset', props: { leadingInset: 'HermesSpacing.s0' } },
        { name: 'Row-aligned inset', props: { leadingInset: 'HermesSpacing.s16' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Tag',
    description:
      'Tag is always display-only: a small tinted-fill pill (semibold caption text on a matching low-opacity fill), modeled on the several independent tinted-fill status pills production already uses for session state, task/run status, Git change kind, and connection/selection state. A tappable element must use a control or link component (see Buttons), not Tag or tag-like styling.',
    whenToUse: 'Use it for a short, glanceable status word or two; a longer message belongs in body text, not a Tag. Never make a Tag (or anything styled like one) tappable.',
    props: [
      { name: 'label', type: 'String', required: true, desc: 'The status text.' },
      { name: 'tint / foreground+fill', type: 'Color', required: true, desc: 'Drives both the text color and the fill (tint.opacity(_:)) in the common case; foreground/fill can also be set independently (Settings\' inverted profile pill).' },
      { name: 'icon', type: 'Optional glyph', desc: 'Optional leading icon shown alongside the label (e.g. a running-status dot).' },
      { name: 'size', type: '.compact | .regular | .prominent', default: '.regular', desc: 'Every horizontal/vertical padding pair a real call site uses today.' },
      { name: 'isDecorative', type: 'Bool', default: 'false', desc: 'Hides the Tag from VoiceOver when the row around it already announces the same fact (Sessions); otherwise announced normally as meaningful content.' },
    ],
    a11y: 'Sessions\' tags are decorative (isDecorative: true) since the row supplies the accessible name; Tasks/Git/Settings tags are announced normally. No Tag prop, example, or styling anywhere in this section is interactive.',
    render: () => <TagGallery />,
    hermesReference: {
      useWhen: 'Use it for a short, glanceable status word or two, always display-only.',
      avoidWhen: 'Never make a Tag (or anything styled like one) tappable, and never use it for a longer message — that belongs in body text.',
      alternatives: [
        { name: 'Buttons', useWhen: 'When the element must be tappable, rather than a display-only status label.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only component; production\'s status pills (Sessions, Tasks, Workspace/Git, Settings, and the composer\'s chip rendering) each keep their own existing, separately-implemented capsule styling in this branch, not Tag.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/Tag.swift',
        ],
        notes: [
          'Production still has several independent, unmigrated capsule-style implementations across Sessions, Tasks, Workspace/Git, and Settings; a future consolidation onto this one shared Tag component has not been made against any of them in this branch.',
          'The composer\'s inline skill/bot/file chip rendering (ComposerChipRendering.swift, ComposerChipToken.swift) is its own separate, pre-existing drawing path with no isInteractiveReference/ComposerChipVisualStyle API and no dependency on this new Tag component — see Composer\'s own Composer Chip coverage for that pattern\'s own accurate description.',
        ],
      },
      canonicalSymbols: ['Tag', 'Tag.Size'],
      usageExamples: [
        { name: 'A running-status pill', language: 'swift', code: `Tag(label: "Running", tint: .green, size: .regular)` },
      ],
      machineConfigurations: [
        { name: 'Compact', props: { size: '.compact' } },
        { name: 'Regular', props: { size: '.regular' } },
        { name: 'Prominent', props: { size: '.prominent' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Text Input',
    description:
      'Three Hermex-owned entry points over native SwiftUI text entry (HermexTextInput.swift) — Default (`HermexTextField`), Password (`HermexSecureField`), and Code (`HermexCodeInput`) — each forwarding to exactly one native editor (`TextField`, `SecureField`, and a single `TextField` driving Code\'s decorative row of digit boxes) with no chrome, validation, or parsing of its own beyond Code\'s fixed digit-entry contract. TextEditor remains a native iOS control for multiline body text, not a newly owned Hermex component, and the Search family (the custom `HermexSearchField`/`.hermexSearch`) stays its own separate entry rather than a Text Input variant.',
    whenToUse: 'Reach for Default (HermexTextField) for an ordinary single-line value, Password (HermexSecureField) for a credential, and Code (HermexCodeInput) for a caller-supplied code between 4 and 8 digits long, with paste and one-time-code autofill support. Use native TextEditor directly for multiline body text. Use the Search family for any query that filters or looks up content, even inline inside a sheet or card — Search is defined by the query behavior, not its placement. For a fixed-option single-selection field, use Hermes Selection Sheet instead of free text.',
    props: [
      { name: 'HermexTextField(_:text:prompt:helperText:errorText:isEnabled:)', type: 'Binding<String>, Text?', desc: 'Default variant: one native `TextField` for ordinary single-line entry, plus a persistent label, optional prompt, and optional helper/error text; the caller keeps owning keyboard, autocorrection, capitalization, and content type exactly as with `TextField` directly.' },
      { name: 'HermexSecureField(_:text:prompt:helperText:errorText:isEnabled:)', type: 'Binding<String>, Text?', desc: 'Password variant: one native `SecureField` for masked single-line entry, such as a credential, with the same label/prompt/helper/error chrome as Default.' },
      { name: 'HermexCodeInput(_:code:length:helperText:errorText:isEnabled:)', type: 'Binding<String>, Int (4...8, default 6), Text?', desc: 'Code variant: exactly one native `TextField` (`.keyboardType(.numberPad)`, `.textContentType(.oneTimeCode)`) drives editing and accessibility for a caller-owned digit-only code between 4 and 8 characters long; a decorative, accessibility-hidden row of boxes mirrors the entered digits. Supports paste and iOS one-time-code autofill. Code never submits on its own — the caller decides when a complete code should be acted on.' },
    ],
    a11y: 'Default and Password each forward straight to their native control, so production keeps native focus, keyboard, clear behavior, dictation, Dynamic Type, and VoiceOver. Code keeps exactly one native editor as the accessibility authority — it groups a native accessibility label, value (digits entered so far, out of the target length), and hint — while its digit-box row is hidden from accessibility as purely decorative.',
    render: () => <HermexTextInputFamilyGallery />,
    hermesReference: {
      useWhen: 'Reach for Default (HermexTextField) for an ordinary single-line value, Password (HermexSecureField) for a credential, and Code (HermexCodeInput) for a code between 4 and 8 digits long with paste/one-time-code autofill. These fields capture values the user keeps; a query that filters or looks up content belongs to Search instead, regardless of placement.',
      avoidWhen: 'Avoid reaching for any of the three for multiline body text (use native TextEditor directly) or for a query that filters or looks up content (use the Search family, even inline inside a sheet or card) — neither is a Text Input variant. Avoid expecting Code to submit on its own — it never does; the caller decides when to act on a complete code.',
      alternatives: [
        { name: 'Hermes Selection Sheet', useWhen: 'For a labeled single-selection field driven by a fixed option list, instead of freeform text entry.' },
        { name: 'Search', useWhen: 'For any query that filters or looks up content, even inline inside a sheet or card, rather than a value the user types and keeps.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'The three wrappers exist (HermexTextInput.swift) and are foundation-available on this branch; zero production screens use them. Production\'s existing direct TextField and SecureField call sites remain unchanged — migrating them onto the wrappers is deferred to a separate adoption issue.',
      },
      useSummary: 'New foundation wrappers; no screen has adopted them yet in this slice. Production keeps its existing direct TextField/SecureField call sites unchanged.',
      implementationNotes: {
        status: 'Component exists (HermexTextInput.swift) with no production call site yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexTextInput.swift'],
        notes: [
          'Deliberately thin: `HermexTextField` forwards to native `TextField`, `HermexSecureField` to native `SecureField`, and `HermexCodeInput` to exactly one native `TextField` whose `.keyboardType(.numberPad)`/`.textContentType(.oneTimeCode)` drive a decorative, accessibility-hidden `ForEach` row of digit boxes — none of the three own a clear button or their own focus, keyboard, autocorrection, or capitalization policy beyond Code\'s fixed digit-entry contract.',
          'Report only: production\'s existing direct TextField and SecureField call sites are unchanged by this branch and continue to call TextField/SecureField directly; migrating them onto the three wrappers is scoped to a separate issue, not this slice.',
          'The chat composer\'s own text entry is a UIKit UITextView wrapped in UIViewRepresentable (ComposerTextView), not TextField/HermexTextField — its keyboard, draft, and attachment behavior stay documented under the Composer pattern, not here.',
          'TextEditor remains a native iOS control for multiline body text; this slice does not add a Hermex-owned multiline wrapper.',
          'This reconstruction uses plain React Native TextInput to approximate HermexTextField/HermexSecureField/HermexCodeInput visually; it does not compose the generic template InputField, which owns a different floating-label/clear-button visual language production does not use. The retained template catalog keeps its own InputField entry separately.',
          'Approved samples: Default uses label "Name" with prompt "Enter your name"; Password uses label "Password" with prompt "Enter your password"; Code uses label "Verification code" with helper "Enter the 6-digit code." and error "Enter all 6 digits."',
        ],
      },
      canonicalSymbols: ['HermexTextField', 'HermexSecureField', 'HermexCodeInput'],
      usageExamples: [
        { name: 'Default single-line field', language: 'swift', code: `HermexTextField("Name", text: $name, prompt: Text("Enter your name"))` },
      ],
      machineConfigurations: [
        { name: 'Default', props: { label: 'Name', prompt: 'Enter your name' } },
        { name: 'Password', props: { label: 'Password', prompt: 'Enter your password' } },
        { name: 'Code', props: { label: 'Verification code', helperText: 'Enter the 6-digit code.', errorText: 'Enter all 6 digits.' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Bottom Sheet',
    description:
      'A Hermex-owned content scaffold — `HermexBottomSheet` (HermexBottomSheet.swift) — supplied to native SwiftUI `.sheet`, never a replacement for the presentation modifier itself. It owns a `NavigationStack` with an inline title, this catalog\'s own TopNav composed through native `.toolbar` at modal-appropriate placements (`.cancellationAction`/`.confirmationAction`), an unconstrained body slot that accepts either arbitrary content or a native `List`, and an optional footer pinned with `.safeAreaInset(edge: .bottom)` that arranges its direct children horizontally or vertically. The caller keeps calling `.sheet` directly — detents, the drag indicator, compact adaptation, interactive-dismiss policy, focus, validation, loading state, and dismissal all stay caller-owned, and native SwiftUI alone chooses adaptive presentation style by platform/context and owns dismissal interaction, presentation motion, and Reduce Motion; bottom attachment may occur where that native presentation chooses it, but this scaffold never defines or guarantees it.',
    whenToUse:
      'Reach for HermexBottomSheet as the content passed to a screen\'s own `.sheet` for a bounded modal task that is more than one decision: a short form, editable content, a multi-option selection or configuration workflow where the user sets or chooses several settings before confirming, or a longer workflow that may scroll. Keep `.sheet` itself, its detents, and its dismissal policy at the call site; this scaffold only supplies what is inside it, never the presentation style itself. For one bounded, full-attention decision with one or two actions, use Dialog instead — Dialog is always centered and never dismissed by a background tap. For a persistent, back-navigable screen rather than a transient modal, use a native NavigationLink/`.navigationDestination` push instead of a sheet.',
    props: [
      { name: 'title', type: 'LocalizedStringKey', required: true, desc: 'The scaffold\'s inline native navigation title.' },
      { name: 'footerAxis', type: '.horizontal | .vertical', default: '.horizontal', desc: 'Arranges the footer slot\'s direct children side by side or stacked — chosen by the caller, never inferred automatically.' },
      { name: 'content', type: '@ViewBuilder', required: true, desc: 'The unconstrained body slot — accepts a native List or arbitrary content with no imposed card, scroll view, padding, or background.' },
      { name: 'leadingPrimary / leadingSecondary', type: '@ViewBuilder', desc: 'The same leading TopNav slots as Hermes TopNav, rendered at `.cancellationAction` placement.' },
      { name: 'trailingPrimary / trailingSecondary', type: '@ViewBuilder', desc: 'The same trailing TopNav slots as Hermes TopNav, rendered at `.confirmationAction` placement.' },
      { name: 'footer', type: '@ViewBuilder', desc: 'Optional; omit for no pinned footer at all. Pinned with native `.safeAreaInset(edge: .bottom)`, never a hard-coded height.' },
    ],
    a11y: 'Header actions live in the shared TopNav\'s own slots, so they keep TopNav\'s accessibilityLabel and touch-target guarantees. The body slot forwards straight to whatever native content is supplied — a List keeps native selection/accessibility, arbitrary content keeps whatever the caller composed — and the pinned footer stays reachable at large Dynamic Type sizes through native `.safeAreaInset` rather than a fixed-height overlay that could clip it.',
    render: () => <HermexBottomSheetFamilyGallery />,
    hermesReference: {
      useWhen: 'Reach for HermexBottomSheet as the content passed to a screen\'s own `.sheet` for a bounded modal task that is more than one decision: a short form, editable content, a multi-option selection or configuration workflow where the user sets or chooses several settings before confirming, or a longer workflow that may scroll. It supplies the TopNav-style header plus an optional pinned footer for Cancel/Done; the caller keeps `.sheet`, its detents, and its dismissal policy.',
      avoidWhen: 'Avoid it for a single bounded confirmation or alert that needs the user\'s full attention — use Dialog, which is always centered and never dismissed by a background tap. Avoid it for a persistent, back-navigable screen — use a native NavigationLink/.navigationDestination push instead of a sheet. Avoid composing a second NavigationStack, TopNav, or footer chrome inside its body slot — the scaffold already owns all three.',
      alternatives: [
        { name: 'Hermes Dialog', useWhen: 'For one bounded, full-attention decision with one or two actions (for example Confirm/Cancel) and no form, scrolling, or multiple settings — Dialog\'s dimmed backdrop never dismisses it.' },
        { name: 'Hermes Selection Sheet', useWhen: 'When the whole task is choosing one or several values from a single fixed option list — Selection Sheet already composes this scaffold with the list, row-owned indicators, and Cancel/Done footer.' },
        { name: 'Native NavigationLink / .navigationDestination (production)', useWhen: 'For a persistent, back-navigable screen instead of a transient, adaptively-presented modal.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'HermexBottomSheet exists (HermexBottomSheet.swift) and is foundation-available on this branch; zero production screens use it. Every existing production `.sheet` keeps its own current header/body/footer anatomy unchanged — migrating one onto this scaffold is deferred to a separate adoption issue.',
      },
      useSummary: 'A new, foundation-only content scaffold for native `.sheet`; no production sheet composes it yet in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/HermexBottomSheet.swift'],
        notes: [
          'Deliberately a content scaffold, not a presentation modifier: the caller keeps calling `.sheet` directly, including its detents, drag indicator, compact adaptation, interactive-dismiss policy, focus, validation, loading state, and dismissal — native SwiftUI alone chooses the adaptive presentation style by platform/context and owns dismissal interaction, presentation motion, and Reduce Motion either way; bottom attachment is never a universal claim this scaffold makes.',
          'Composes the existing TopNav (HermesMobile/Features/Shared/TopNav.swift) through native `.toolbar` at `.cancellationAction`/`.confirmationAction` placements rather than a hand-rolled in-content bar. HermexBottomSheet itself — not TopNav.swift\'s own global defaults — scopes an XS/neutral/adaptive-glass `.buttonStyle(.hermex(.extraSmall, emphasis: .neutral, isGlass: true))` default to its four TopNav slots at this composition boundary, preferring familiar icons with accessible labels; a caller may still apply its own explicit button style directly inside a slot to override it. The pinned footer has no divider or border of its own.',
          'The body `@ViewBuilder` slot is intentionally unconstrained — no card, scroll view, padding, or background — so it accepts a native List or arbitrary content without breaking either context.',
          'This reconstruction hand-builds the header/body/footer anatomy from this catalog\'s own real TopNav/List/ListItem/Button primitives; it does not compose the generic template catalog\'s own BottomSheet component, which owns a slide-up/backdrop/handle animation language production\'s native `.sheet` does not use.',
          'Report only: no production `.sheet` call site imports or composes HermexBottomSheet.swift in this branch; every existing sheet keeps its own current header/body/footer anatomy. Migrating one onto it is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexBottomSheet'],
      usageExamples: [
        { name: 'Sheet with a trailing Done action', language: 'swift', code: `.sheet(isPresented: $isPresented) {
    HermexBottomSheet("Choose a Model") {
        List(models) { model in Text(model.name) }
    } trailingPrimary: {
        Button("Done") { isPresented = false }
    }
}` },
      ],
      machineConfigurations: [
        { name: 'Horizontal footer', props: { footerAxis: '.horizontal' } },
        { name: 'Vertical footer', props: { footerAxis: '.vertical' } },
        { name: 'No footer', props: { footer: 'omitted' } },
      ],
      compositionSlots: [
        {
          name: 'content', description: 'The unconstrained body slot — accepts a native List or arbitrary content.', required: true, cardinality: 'one', acceptedContent: ['generic-view'],
          order: 0, role: 'body-content',
          layout: { placement: 'component-fixed', axis: 'vertical', position: 'sheet body, below the nav bar' },
          overflow: 'scroll', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'leadingPrimary', description: 'Leading TopNav slot, rendered at .cancellationAction placement.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 1, role: 'leading-action',
          layout: { placement: 'component-fixed', axis: 'none', position: 'nav bar, leading edge (.cancellationAction)' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'leadingSecondary', description: 'Second, less prominent leading TopNav slot.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 2, role: 'leading-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'nav bar, leading edge, closer to the title' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'trailingPrimary', description: 'Trailing TopNav slot, rendered at .confirmationAction placement.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 3, role: 'trailing-action',
          layout: { placement: 'component-fixed', axis: 'none', position: 'nav bar, trailing edge (.confirmationAction)' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'trailingSecondary', description: 'Second, less prominent trailing TopNav slot.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 4, role: 'trailing-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'nav bar, trailing edge, closer to the title' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'footer', description: 'Optional footer pinned with .safeAreaInset(edge: .bottom).', required: false, cardinality: 'zero-or-more', acceptedContent: ['generic-view', 'control'],
          order: 5, role: 'footer',
          layout: { placement: 'caller-ordered', axis: 'horizontal', position: "pinned to the bottom edge via .safeAreaInset(edge: .bottom); axis defaults to .horizontal, caller may choose .vertical" },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
          ownership: "The caller's own footer-child order is preserved along the chosen axis; each child owns its own interaction.",
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Dialog',
    displayName: 'Dialog',
    description:
      'A fully custom, always-centered modal — `HermexDialog` (HermexDialog.swift), presented via the `.hermexDialog(isPresented:footerAxis:header:content:footer:)` view modifier — mounted through the shared same-window overlay host rather than any native `.alert`, `.sheet`, `fullScreenCover`, or other presentation wrapper. Hermex owns the dimmed backdrop, centered card geometry, focus, accessibility containment, motion, and exactly-once dismissal/action completion. The header row vertically centers the caller-supplied heading against a compact XS adaptive-glass close control that keeps its 44pt minimum hit target; the dimmed backdrop never dismisses it. The caller lays the footer out horizontally (actions hug the trailing edge, authored lower emphasis first and higher emphasis last) or vertically.',
    whenToUse:
      'Reach for Dialog for a short, focused interruption or confirmation that needs the user\'s full attention — a destructive confirmation, or a brief explanation with one or two actions. Never use it for forms, text input, long content, or a browsable flow: it never scrolls and never accepts text input by design. Background taps never dismiss it, unlike a native sheet or popover; the component always supplies the standard close button and accessibility Escape, while the caller supplies the footer actions. Forms, editable content, and longer content belong in Bottom Sheet instead.',
    props: [
      { name: 'isPresented', type: 'Binding<Bool>', required: true, desc: 'Caller-owned presentation state. The modifier writes it back to false only once exit visually completes, never at exit start.' },
      { name: 'footerAxis', type: '.horizontal | .vertical', default: '.horizontal', desc: 'Arranges the footer slot\'s direct children side by side or stacked — chosen by the caller, never inferred from action count or width.' },
      { name: 'header', type: '@ViewBuilder', required: true, desc: 'Leading header content read first by VoiceOver; the standard close button always sits vertically centered with it at the row\'s trailing edge.' },
      { name: 'content', type: '@ViewBuilder', required: true, desc: 'Short body content. No internal scrolling and no text fields/forms — the component never silently becomes a scrolling dialog.' },
      { name: 'footer', type: '(HermexOverlayActionContext) -> View', required: true, desc: 'Receives an action context whose dismiss()/dismissAfter(_:) request dismissal; dismissAfter defers exactly one action until after exit completes. The horizontal axis aligns the caller\'s own action order to the trailing edge without reordering it; the vertical axis stacks it unchanged.' },
    ],
    a11y: 'The same-window host isolates the underlying screen from touch and accessibility while presented. Initial VoiceOver focus lands on the heading; reading order is heading, body, footer, then close, even though close sits visually in the header row. The close button\'s visual chrome is a compact XS adaptive-glass control, but it keeps a stable "Close dialog" accessible name and the project-standard 44pt minimum touch target regardless. Accessibility Escape and the close button share one dismissal path, and focus returns to the presenting trigger once the dialog closes.',
    render: () => <DialogFamilyGallery />,
    hermesReference: {
      useWhen: 'Use Dialog for a disruptive, full-attention interruption that asks the user for exactly one bounded decision before they continue — a destructive confirmation, a permission, or a brief explanation they must acknowledge. One decision means one question; it may expose two choices such as Confirm/Cancel, but never several independent settings, a form, or scrolling content.',
      avoidWhen: 'Avoid it for forms, text input, long or scrolling content, or ordinary navigation. Avoid it when the user must choose or configure several settings, or pick from an option list — that is Bottom Sheet or Selection Sheet, not a second Dialog question. Avoid it for a short list of anchored actions on a trigger — use Popover Menu. Avoid expecting a background tap to dismiss it — that never happens by design; the component supplies the close button and Escape, while the caller supplies the footer actions for the one decision.',
      alternatives: [
        { name: 'Bottom Sheet', useWhen: 'For forms, editable content, or a longer mobile workflow that needs scrolling — Dialog never scrolls and never accepts text input.' },
        { name: 'Hermes Popover Menu', useWhen: 'For a short list of simple anchored actions on a trigger that run once and dismiss, rather than a centered full-attention decision.' },
        { name: 'Hermes Selection Sheet', useWhen: 'When the decision is choosing one or several values from a fixed option list rather than answering one bounded question.' },
        { name: 'Native NavigationLink / .navigationDestination (production)', useWhen: 'For a persistent, back-navigable screen instead of a transient, full-attention interruption.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'HermexDialog exists (HermexDialog.swift) and is foundation-available on this branch; zero production screens use it. Every existing production confirmation/alert keeps its own current presentation unchanged — migrating one onto Dialog is deferred to a separate adoption issue.',
      },
      useSummary: 'A new, foundation-only fully custom modal; no production screen composes it yet in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/HermexDialog.swift',
          'HermesMobile/Features/Shared/HermexSameWindowOverlay.swift',
          'HermesMobile/Features/Shared/HermexOverlayLifecycle.swift',
        ],
        notes: [
          'Mounted through HermexSameWindowOverlay (.root bounds) — the same reusable same-window UIHostingController mechanism the attachment picker\'s HermexKeyboardRetainingOverlay originally proved. That picker (HermesMobile/Features/Chat/CustomAttachmentPicker.swift) keeps its own local, pre-existing same-window implementation in production rather than importing this foundation file — rather than any native .alert, .sheet, fullScreenCover, Menu, or .popover.',
          'The header row uses HStack(alignment: .center) so the heading and close control align on the same vertical center. The close control composes the shared HermexButton at size: .extraSmall, emphasis: .neutral, isGlass: true — the same adaptive-glass chrome as Buttons\' Glass surface — wrapped in a 44pt minWidth/minHeight frame so the compact 24pt visual keeps the project-standard touch target. The horizontal footer case adds a leading Spacer so the caller\'s own action order hugs the semantic trailing edge without reordering it; the vertical case is unchanged.',
          'Exactly-once dismissal and deferred-action completion are owned by a small generation-based HermexOverlayLifecycle state machine, shared with the same-window host mechanism and intended for reuse by the next approved family in this same slice (Popover Menu, not yet part of this branch).',
          'Entry/exit motion reuses the existing HermesMotion.Bundle.overlayEnter/overlayExit bundles (scrim fade plus centered 0.95→1 scale and opacity); Reduce Motion removes the scale and keeps an opacity-only state change. Reduce Transparency falls back through the existing hermexCardSurface(.glass) solid-card treatment.',
          'This reconstruction hand-builds the header/close/body/footer anatomy from this catalog\'s own real Card/Button primitives; it does not reuse the generic template catalog\'s own Dialog, whose background-tap-dismisses behavior would contradict this component\'s non-dismissible backdrop.',
          'Report only: no production confirmation/alert call site imports or composes HermexDialog.swift in this branch; every existing one keeps its own current presentation unchanged. Migrating one onto Dialog is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexDialog', '.hermexDialog(isPresented:footerAxis:header:content:footer:)', 'HermexOverlayActionContext'],
      usageExamples: [
        { name: 'Destructive confirmation', language: 'swift', code: `.hermexDialog(isPresented: $isPresented) {
    Text("Delete session?")
} content: {
    Text("This action can't be undone.")
} footer: { context in
    Button("Cancel") { context.dismiss() }
    Button("Delete", role: .destructive) { context.dismissAfter { delete() } }
}` },
      ],
      machineConfigurations: [
        { name: 'Horizontal footer', props: { footerAxis: '.horizontal' } },
        { name: 'Vertical footer', props: { footerAxis: '.vertical' } },
      ],
      compositionSlots: [
        {
          name: 'header', description: 'Leading header content read first by VoiceOver; the standard close button sits at the row\'s trailing edge.', required: true, cardinality: 'one', acceptedContent: ['generic-view', 'text'],
          order: 0, role: 'header',
          layout: { placement: 'component-fixed', axis: 'horizontal', position: 'top row, leading edge, vertically centered against the close control' },
          overflow: 'wrap', interactionOwnership: 'none', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'content', description: 'Short body content. No internal scrolling and no text fields/forms.', required: true, cardinality: 'one', acceptedContent: ['generic-view', 'text'],
          order: 1, role: 'body-content',
          layout: { placement: 'component-fixed', axis: 'vertical', position: 'card body, below the header row' },
          overflow: 'clip', interactionOwnership: 'none', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'footer', description: 'Receives a HermexOverlayActionContext whose dismiss()/dismissAfter(_:) request dismissal.', required: true, cardinality: 'zero-or-more', acceptedContent: ['control'],
          order: 2, role: 'footer',
          layout: { placement: 'caller-ordered', axis: 'horizontal', position: 'bottom edge; axis is caller-chosen (.horizontal default or .vertical)' },
          overflow: 'wrap', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
          ownership: 'The horizontal axis aligns the caller\'s own action order to the trailing edge without reordering it; the vertical axis stacks it unchanged.',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Popover Menu',
    displayName: 'Popover Menu',
    description:
      'A fully custom, always trigger-anchored floating menu — `HermexPopoverMenu` (HermexPopoverMenu.swift), presented via the `.hermexPopoverMenu(isPresented:accessibilityLabel:actions:)` view modifier — mounted through the same shared same-window overlay host and `HermexOverlayLifecycle` as Dialog, never a native `Menu`, `.contextMenu`, or `.popover`. It prefers below the trigger, flips above when below doesn\'t fit, and clamps horizontally inside the safe area; it is anchored-only, with no per-size-class fallback to another presentation. Rows are simple, stable-ID actions (title, optional symbol, enabled state, standard/destructive role) rendered through `HermexList(style: .compactOverlay)` + `ListItem` — no nested submenus, toggles, or a persistent selection model in this v1.',
    whenToUse:
      'Reach for Popover Menu for a short list of simple, anchored actions on a trigger — a row\'s overflow menu, a "…" button\'s Rename/Duplicate/Delete. Its accessibility label is always caller-supplied — there is no generic hidden default such as "Actions". Use Dialog instead for a full-attention modal decision or confirmation, and Bottom Sheet instead for forms, editable content, or a longer scrolling workflow.',
    props: [
      { name: 'isPresented', type: 'Binding<Bool>', required: true, desc: 'Caller-owned presentation state, written back to false only once exit visually completes.' },
      { name: 'accessibilityLabel', type: 'Text', required: true, desc: 'Required, caller-supplied name for the menu\'s modal accessibility container — never a generic default.' },
      { name: 'actions', type: '[HermexPopoverMenuAction]', required: true, desc: 'Stable-ID rows: id, title, optional systemImage, isEnabled, role (.standard | .destructive), and one action closure.' },
      { name: 'HermexPopoverMenuMetrics.contentPadding', type: 'CGFloat', default: 'HermesSpacing.s16', desc: 'One 16pt internal padding around the compact action list, inside the fixed menu surface. Rows compose ListItem\'s contentInset: .none so this one 16pt boundary is never doubled by a second, row-level inset; preferred-size estimation includes this padding so placement never clips or forces unnecessary internal scrolling.' },
    ],
    a11y: 'Initial VoiceOver focus lands on the first enabled action. The menu is one accessibility-contained modal element with accessibility Escape wired to dismissal. A disabled row stays visible but is never selectable, and a destructive row\'s meaning is always textual (an accessibility hint), never color-only. Tapping outside the menu, or Escape, dismisses it without running an action; activating an enabled row runs its action exactly once, after exit completes — the same exactly-once dismissal/action-completion guarantee as Dialog.',
    render: () => <PopoverMenuFamilyGallery />,
    hermesReference: {
      useWhen: 'Use Popover Menu for a short list of simple, anchored actions on a trigger — it is always trigger-anchored, flips above/below to stay on screen, and clamps horizontally inside the safe area.',
      avoidWhen: 'Popover Menu is for actions only. Avoid it for explanatory or informational content with nothing to run — use Tooltip for an anchored aside. Avoid it as a navigation surface or destination list — use a NavigationLink or List / ListItem rows. Avoid it for a full-attention modal decision or confirmation — use Dialog. Avoid it for forms, editable content, or a longer scrolling workflow — use Bottom Sheet. Avoid it for nested submenus, toggles, or a persistent selection model — none exist in this v1; route any persistent selection to a caller-presented Selection Sheet or a dedicated picker sheet instead of Popover Menu.',
      alternatives: [
        { name: 'Dialog', useWhen: 'For a full-attention modal decision or confirmation the user must resolve before continuing.' },
        { name: 'Bottom Sheet', useWhen: 'For forms, editable content, or a longer mobile workflow that needs scrolling.' },
        { name: 'Hermes Selection Sheet', useWhen: 'For a persistent single- or multi-selection choice rather than a one-off action list.' },
        { name: 'Hermes Tooltip', useWhen: 'For anchored explanatory content with no action to run — Popover Menu rows are actions only.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'HermexPopoverMenu exists (HermexPopoverMenu.swift) and is foundation-available on this branch; zero production screens use it. Every existing production overflow/context menu keeps its own current presentation unchanged — migrating one onto Popover Menu is deferred to a separate adoption issue.',
      },
      useSummary: 'A new, foundation-only fully custom menu; no production screen composes it yet in this branch.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/HermexPopoverMenu.swift',
          'HermesMobile/Features/Shared/HermexSameWindowOverlay.swift',
          'HermesMobile/Features/Shared/HermexOverlayLifecycle.swift',
          'HermesMobile/Features/Shared/HermexList.swift',
        ],
        notes: [
          'Mounted through HermexSameWindowOverlay (.root bounds) and HermexOverlayLifecycle, the same reusable same-window host and generation-based lifecycle state machine Dialog uses — not a bespoke overlay or dismissal mechanism.',
          'Rows compose HermexList(style: .compactOverlay) + ListItem — the same transparent, separator-free List style documented in the List / ListItem entry — rather than a hand-built row stack.',
          'Entry/exit motion reuses the existing HermesMotion.Bundle.overlayEnter/overlayExit bundles and respects Reduce Motion, the same as Dialog; placement geometry (preferred width 280pt, 12pt safe-area margin, 8pt anchor gap) is a pure, testable HermexPopoverPlacement resolver, not a measurement pass.',
          'Report only: no production call site imports or composes HermexPopoverMenu.swift in this branch; every existing overflow/context action in production keeps its own current presentation unchanged. Migrating one onto Popover Menu is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexPopoverMenu', '.hermexPopoverMenu(isPresented:accessibilityLabel:actions:)', 'HermexPopoverMenuAction'],
      usageExamples: [
        { name: 'Row overflow menu', language: 'swift', code: `.hermexPopoverMenu(isPresented: $showsMenu, accessibilityLabel: Text("Row actions"), actions: [
    HermexPopoverMenuAction(id: "rename", title: "Rename") { rename() },
    HermexPopoverMenuAction(id: "delete", title: "Delete", role: .destructive) { delete() },
])` },
      ],
      machineConfigurations: [
        { name: 'Standard enabled action', props: { role: '.standard', isEnabled: true } },
        { name: 'Disabled action', props: { isEnabled: false } },
        { name: 'Destructive action', props: { role: '.destructive' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Search',
    description:
      'One custom Hermex-owned search field, `HermexSearchField`, plus `.hermexSearch(...)`, a convenience modifier that composes that exact field as a persistent top content inset. `HermexSearchField` owns its chrome (an adaptive Neutral surface and border, resting/focused/disabled), local focus, the conditional clear control, and keyboard-submit wiring; the system-backed `TextField` still owns text editing, selection, dictation, IME/composition, autocorrection, and platform text-entry accessibility. Native `.searchable` remains a valid, supported control and is what production\'s screen-level search uses today; `HermexSearchField` does not replace or deprecate it. The difference is placement ownership: `.searchable` lets the system place and draw the field in navigation chrome, while `HermexSearchField` draws Hermex chrome inside the content.',
    whenToUse: 'Keep native `.searchable` when a screen\'s search belongs in the system navigation chrome — production\'s existing search screens do this. Reach for `HermexSearchField` when the search field is part of the content, and use `.hermexSearch` when that same field should stay pinned above a scrolling list. Search is defined by query behavior, not placement, so an inline lookup inside a sheet or card is still Search. Write a concise title and optional prompt, keep query edits live through the caller\'s binding, and pair filtered emptiness with a specific no-results state — the field never owns results.',
    props: [
      { name: 'title', type: 'LocalizedStringKey', required: true, desc: 'Caller-owned localizable title; doubles as the field\'s persistent accessibility label.' },
      { name: 'text', type: 'Binding<String>', required: true, desc: 'Live query binding; the field owns local focus, clear, and keyboard-submit wiring around it, while the caller owns filtering and results.' },
      { name: 'prompt', type: 'Text?', desc: 'Optional visual empty-field guidance such as "Search sessions"; omit for no synthetic copy.' },
      { name: 'isEnabled', type: 'Bool', default: 'true', desc: 'Disabling prevents editing, clear, and submission, and resigns focus if the field was focused when it changed.' },
      { name: 'onSubmit', type: '() -> Void', desc: 'Runs once when the keyboard Search action fires; the query is unchanged by submission.' },
    ],
    a11y: 'The caller\'s title is the persistent accessible label; the search icon is decorative and hidden from accessibility. The clear control is exposed only while the query is nonempty, announces "Clear search", and keeps an independent 44pt minimum hit target. Dynamic Type may grow the field\'s height without clipping; RTL mirrors visual order while preserving logical leading/trailing behavior; Increased Contrast strengthens the border; Reduce Transparency falls back to an opaque surface.',
    render: () => <SearchFamilyGallery />,
    hermesReference: {
      useWhen: 'Use `HermexSearchField` when a query field is part of the content — inline inside a sheet or card — and `.hermexSearch(...)` when that same field should stay pinned above a scrolling list. Native `.searchable` stays valid when the system should own search placement in navigation chrome. Pair filtered emptiness with a specific no-results state.',
      avoidWhen: 'Avoid treating this entry as a mandate to replace a working native `.searchable` screen; migrating a screen is a separate, deliberate adoption decision. Avoid adding scopes, suggestions, history, tokens/scopes, voice UI, remote requests, debounce, or result ownership to the field itself — the caller keeps owning filtering, results, loading, and error/no-results presentation.',
      alternatives: [
        { name: 'Text Input', useWhen: 'For a value the user types and keeps — a name, URL, credential, or code — rather than a query that filters or looks up content; any filter or lookup field is Search, even inline inside a sheet or card.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'HermexSearchField is internally composed by the foundation-only `HermexSelectionSheet.swift` for its optional search slot — but HermexSelectionSheet itself has no normal-runtime production call site (its only caller is the DEBUG-only HermexOverlayLab), so that internal composition is not a production adoption of Search. Production\'s eight existing screen-level search fields (Sessions, Model picker, Skills, Default profile, Cron job profile/skill pickers, Git branch picker, Kanban) still call native `.searchable` directly; migrating a screen onto `.hermexSearch` is deferred to a separate issue.',
      },
      useSummary: 'HermexSearchField is foundation-only: it is composed internally by the foundation-only `HermexSelectionSheet.swift`, which itself has no normal-runtime production call site. No production screen has adopted `HermexSearchField` or `.hermexSearch`; production keeps its existing eight direct `.searchable` call sites unchanged.',
      implementationNotes: {
        status: 'Foundation-available; composed internally by the foundation-only HermexSelectionSheet.swift, which has no normal-runtime production call site. No screen-level `.searchable` call site has migrated yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexSearch.swift', 'HermesMobile/Features/Shared/HermexSelectionSheet.swift'],
        notes: [
          'One canonical visual implementation: `HermexSearchField` owns chrome, local `@FocusState`, the clear control, and `.submitLabel(.search)`/`.onSubmit` wiring around a native `TextField`; `.hermexSearch(...)` only composes that same field as a `.safeAreaInset(edge: .top)` — there is no second field implementation.',
          'Native `.searchable` remains valid and production-used: HermexSearchField is an additional Hermex-owned option, not a replacement. A Hermex-drawn field cannot reproduce the system\'s navigation-chrome placement, so a screen that wants that placement keeps `.searchable`.',
          'HermexSelectionSheet.swift\'s optional search slot renders HermexSearchField directly, but HermexSelectionSheet.swift itself is only called by the DEBUG-only HermexOverlayLab — not a normal-runtime production screen — so this internal composition is not a production call site for Search.',
          'Report only: production\'s eight existing direct `.searchable` screen call sites (SessionListComponents.swift, ModelPickerSheet.swift, SkillsView.swift, DefaultProfilePickerView.swift, CronJobConfigurationPickers.swift, CronJobSkillsPicker.swift, GitBranchPickerView.swift, KanbanLabView.swift) are unchanged by this branch and continue to call `.searchable` directly; migrating a screen onto `.hermexSearch` is scoped to a separate issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexSearchField', '.hermexSearch(_:text:prompt:isEnabled:onSubmit:)'],
      usageExamples: [
        { name: 'Pinned search above a scrolling list', language: 'swift', code: `List(sessions) { session in Text(session.title) }
    .hermexSearch("Search sessions", text: $query, prompt: Text("Search sessions"))` },
      ],
      machineConfigurations: [
        { name: 'Enabled, with prompt', props: { isEnabled: true, prompt: 'Search sessions' } },
        { name: 'Disabled', props: { isEnabled: false } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Segmented Control',
    description:
      'One custom Hermex mutually-exclusive selection family with two presentations: fixed divides the available width equally for compact option sets and grows vertically with up to two centered label lines at accessibility text sizes; scrolling preserves each option\'s intrinsic width for larger sets. Both share Button semantics, typography, selected-pill treatment, and a Reduce-Motion-safe selection transition.',
    whenToUse: 'Use fixed for short, stable sets such as task filters, usage windows, and Cost/Tokens. Use scrolling for a larger horizontal set such as Kanban statuses. Use Checkbox for independent multi-selection and Tag only for display-only labels.',
    props: [
      { name: 'selection', type: 'Binding<Value>', required: true, desc: 'The single selected value.' },
      { name: 'options', type: '[SegmentedControlOption<Value>]', required: true, desc: 'Title plus optional count and tint for each mutually-exclusive option.' },
      { name: 'style', type: '.fixed | .scrolling', default: '.fixed', desc: 'Equal-width track or horizontally scrolling intrinsic-width presentation.' },
    ],
    a11y: 'Both variants expose one native Button per option, an explicit selected trait, a 44pt minimum touch target around the compact 36pt visible pill, and an instant state change when Reduce Motion is enabled.',
    render: () => <SegmentedControlGallery />,
    hermesReference: {
      useWhen: 'Use fixed for short, stable sets such as task filters, usage windows, and Cost/Tokens. Use scrolling for a larger horizontal set such as Kanban statuses.',
      avoidWhen: 'Avoid it for independent multi-selection — use Checkbox — or for a purely display-only label — use Tag.',
      alternatives: [
        { name: 'Hermes Checkbox', useWhen: 'For independent multi-selection rather than mutually exclusive choice.' },
        { name: 'Tag', useWhen: 'For a display-only label rather than an interactive selection control.' },
        { name: 'Hermes Radio', useWhen: 'For a list-style one-of-many choice inside a form, not a top-level view switch.' },
        { name: 'Hermes Selection Sheet', useWhen: 'For a longer option list than fits a fixed track.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only component; the displayed name intentionally omits a Hermex prefix. Tasks and Usage each keep their own existing, direct native SwiftUI segmented control, and Kanban keeps its own UIKit status-control strip, in this branch; migrating any of them is separate, issue-driven work, not something this foundation audit counts or gates.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/SegmentedControl.swift',
        ],
        notes: [
          'TasksView.swift, InsightsView.swift, and UsageChartCard.swift each still construct their own native SwiftUI segmented control directly, and KanbanLabView.swift keeps its own UIKit status-control strip (KanbanStatusControl); none imports SegmentedControl.swift in this branch. Migrating any of them is separate, issue-driven work — this foundation audit does not count or gate native-control call sites.',
        ],
      },
      canonicalSymbols: ['SegmentedControl', 'SegmentedControlOption'],
      usageExamples: [
        { name: 'Fixed task filter', language: 'swift', code: `SegmentedControl("Filter", selection: $filter, options: filterOptions, style: .fixed)` },
      ],
      machineConfigurations: [
        { name: 'Fixed', props: { style: '.fixed' } },
        { name: 'Scrolling', props: { style: '.scrolling' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Buttons',
    description:
      'Native SwiftUI Button stays the semantic control everywhere. Hermex layers two reusable ButtonStyle families on top for chrome and press feedback, spanning extra-small through large sizes, label/icon content layouts, five emphases, and resting/pressed/disabled/pending states, with an optional Adaptive Glass surface.',
    whenToUse: 'Reach for .hermex(_:emphasis:pressFeedback:isGlass:) for a button whose chrome (fill, size, emphasis) Hermex should supply; reach for .hermexPressOnly(_:shadow:) when a caller already owns its own shape/fill — an icon, a compact control, a capsule, a card, a thumbnail — and only needs Reduce-Motion-safe press feedback. A Yes/No/Approve/Deny choice uses .hermex(_:emphasis:) with .primary/.secondary/.destructive.',
    props: [
      { name: 'HermexButtonPressOnlyStyle.Chrome', type: '.icon | .compactControl | .capsule | .card | .thumbnail', required: true, desc: 'Each has its own pressed scale/opacity/duration/anchor and an optional resting/pressed HermesShadow pair — a ButtonStyle for caller-owned chrome, not a label API.' },
      { name: 'HermexButtonEmphasis', type: '.brandPrimary | .neutral | .primary | .secondary | .destructive', required: true, desc: 'Fill/border/foreground per emphasis on HermexButtonStyle. brandPrimary uses Gold 500, Gold 600 pressed, and a black label; the other decision roles retain their established mappings.' },
      { name: 'HermexButtonPressFeedback', type: '.standard | .emphasized | .none', default: '.standard', desc: 'Standard is the default — Reduce-Motion-safe scale + opacity; Emphasized is a stronger response for a button that wants extra weight; None opts a button out entirely.' },
      { name: 'size', type: 'extraSmall | small | medium | large', default: 'large', desc: 'Generic catalog Button\'s own size scale — the closest reusable model for the extra-small-through-large requirement.' },
      { name: 'glass surface option', type: 'Bool', desc: 'Composes Adaptive Glass rather than duplicating its availability/accessibility fallback logic (see the Adaptive Glass Material entry).' },
      { name: 'haptic', type: '(() -> Void)?', desc: 'Optional, semantic haptic fired alongside the action on HermexButton — never implied by Press Feedback.' },
    ],
    a11y: 'Both styles honor Reduce Motion (scale/spring effects drop out) via the shared applyingHermexButtonPressFeedback helper, and Environment(\\.isEnabled) for a dimmed, non-interactive disabled state — native SwiftUI Button semantics (role, label, accessibilityLabel) are untouched by either style.',
    render: () => <ButtonDecisionAndTactilePreview />,
    hermesReference: {
      useWhen: 'Reach for .hermex(_:emphasis:pressFeedback:isGlass:) for a button whose chrome Hermex should supply; reach for .hermexPressOnly(_:shadow:) when a caller already owns its own shape/fill and only needs Reduce-Motion-safe press feedback.',
      avoidWhen: 'Avoid .hermex(_:emphasis:) on a control whose chrome another component already owns (a Segmented Control option, a ListItem row, a Tag-styled pill) — use .hermexPressOnly or that component.',
      alternatives: [
        { name: 'ChatTactileButtonStyle / ChatDecisionButtonStyle (production)', useWhen: 'For any current Sessions, Bots, or composer control — the adopted styles every production call site still uses.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only pair of ButtonStyle modifiers; the Sessions/Bots decision controls and the 18+ composer/thumbnail/capsule/card controls named below all still call the pre-existing, unmigrated ChatTactileButtonStyle (.chatTactile(_:)) and ChatDecisionButtonStyle in this branch, not HermexButtonStyle/HermexButtonPressOnlyStyle.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/HermexButton.swift'],
        notes: [
          'The generic catalog\'s own Button component (primary/secondary/tertiary/white/ghost/destructive, extraSmall/small/medium/large) is the closest reusable emphasis and size model shown above — HermexButtonStyle/HermexButtonPressOnlyStyle are ButtonStyle modifiers applied to a native Button, not a separate label/variant component, so they are documented here rather than reproduced as a second custom tap view.',
          'ChatTactileButtonStyle.swift (HermesMobile/Features/Chat/ChatTactileButtonStyle.swift) is unchanged and still actively used by 18+ production files via .chatTactile(_:) in this branch — HermexButtonPressOnlyStyle does not replace or rename it, and no .hermexPressOnly(_:) call site exists in production yet. Likewise, the Sessions approval overlay and the Bot pending-request card keep calling .chatDecision(_:) directly, not .hermex(_:emphasis:).',
        ],
      },
      canonicalSymbols: [
        'HermexButtonStyle',
        'HermexButtonPressOnlyStyle',
        'HermexButtonEmphasis',
        '.hermex(_:emphasis:pressFeedback:isGlass:)',
        '.hermexPressOnly(_:shadow:)',
      ],
      usageExamples: [
        { name: 'Primary emphasis action', language: 'swift', code: `Button("Approve") { approve() }
    .buttonStyle(.hermex(.large, emphasis: .primary))` },
      ],
      machineConfigurations: [
        { name: 'Brand primary', props: { emphasis: '.brandPrimary' } },
        { name: 'Neutral', props: { emphasis: '.neutral' } },
        { name: 'Primary', props: { emphasis: '.primary' } },
        { name: 'Secondary', props: { emphasis: '.secondary' } },
        { name: 'Destructive', props: { emphasis: '.destructive' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Checkbox',
    displayName: 'Checkbox',
    description:
      'A reusable square multi-selection control: the box fills with HermexSelectionControlColors.selected (Neutral.s950 in light appearance, Neutral.s50 in dark — not a fixed accent), while the checkmark uses the inverse selectedForeground pair so it remains legible against either. Pass an action (the generic catalog Checkbox\'s `onChange`) when the checkbox owns interaction; when a containing row owns the tap instead — a multi-select list row, for example — omit it, and the identical box/checkmark visual renders as a non-interactive, accessibility-hidden indicator so controls are never nested.',
    whenToUse: 'Use it for an independent multi-select fact recorded for a future action (e.g. a form submit) — checking one has no effect on others. For a setting that takes effect immediately, use native Toggle; for one-of-many exclusive selection, use Radio; for a status or completion mark (Tag) or an ordinary picker row\'s selected checkmark (List / ListItem), use that component instead — Checkbox always means an editable multi-select choice.',
    props: [
      { name: 'checked', type: 'Bool', required: true, desc: 'Whether the box is filled and shows the checkmark.' },
      { name: 'onChange', type: '((Bool) -> Void)?', desc: 'Omit when a containing row owns the tap — the checkbox then renders as a non-interactive, accessibility-hidden indicator instead of a second, nested interactive control. Pass it to make the checkbox itself the tap target.' },
      { name: 'label', type: 'String?', desc: 'Optional inline label after the box. Not announced in the row-owned indicator configuration — the owning row supplies its own accessible name/state.' },
      { name: 'disabled', type: 'Bool', default: 'false', desc: 'Dims the control and disables interaction.' },
    ],
    a11y: 'With `onChange`, the box exposes accessibilityRole="checkbox" and accessibilityState.checked/disabled, is reachable by Tab, shows a visible focus ring, and toggles on tap or Space/Enter. Without `onChange`, the identical visual is hidden from assistive technology (accessibilityElementsHidden) so a containing row\'s own Pressable and accessibilityState.selected remain the only interactive/accessible control for that row — never a checkbox nested inside another control.',
    render: () => <CheckboxFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it for an independent multi-select fact recorded for a future action — checking one has no effect on others.',
      avoidWhen: 'Avoid it for a setting that must take effect immediately (use native Toggle), one-of-many exclusive selection (use Radio), or a status/completion mark (use Tag or a List/ListItem checkmark).',
      alternatives: [
        { name: 'Hermes Radio', useWhen: 'For one-of-many exclusive selection.' },
        { name: 'Tag', useWhen: 'For a read-only status or completion mark.' },
        { name: 'Native Toggle', useWhen: 'For a setting that takes effect immediately.' },
        { name: 'List / ListItem', useWhen: 'For an ordinary picker row\'s selected checkmark.' },
        { name: 'Segmented Control', useWhen: 'For a prominent exclusive view switch.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only component; production\'s Bots multi-select question and Kanban\'s bulk card-selection rows each keep their own existing, independent selection-indicator implementation in this branch, not HermexCheckbox.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/HermexCheckbox.swift',
        ],
        notes: [
          'BotPendingRequestCard.swift and KanbanLabView.swift do not import HermexCheckbox.swift in this branch; each still draws its own selection indicator directly.',
          'The interactive configuration (passing action) renders a native Button with an .accessibilityRepresentation(Toggle(...)) so it is announced and operated as a real toggle, not a plain button; the row-owned configuration (action omitted) instead applies .accessibilityHidden(true) to the same visual.',
          'The checked fill and border use HermexSelectionControlColors.selected (Neutral.s950 in light, Neutral.s50 in dark); the checkmark uses selectedForeground, the inverse Neutral pair. The mapping is component-scoped and intentionally avoids Color.accentColor.',
          'HermexSelectionControlColors\' pairings are contrast-validated, component-scoped: unselectedBorder is Neutral.adaptive(light: Neutral.s500, dark: Neutral.s600), corrected from the retired, under-contrast light Neutral.s400 (#AEAEB1, ~2.1:1) to the validated Neutral.s500 (#8E8E93, >=3:1 against the primary surface, WCAG 1.4.11).',
        ],
      },
      canonicalSymbols: ['HermexCheckbox', 'HermexSelectionControlColors'],
      usageExamples: [
        { name: 'Interactive checkbox', language: 'swift', code: `HermexCheckbox(isChecked: isChecked, label: "Include attachments") {
    isChecked.toggle()
}` },
      ],
      machineConfigurations: [
        { name: 'Interactive (owns the tap)', props: { onChange: 'provided' } },
        { name: 'Row-owned indicator', props: { onChange: 'omitted' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Radio',
    displayName: 'Radio',
    description:
      'A reusable circular one-of-many selection control — the selected option shows a filled center dot, with the selected ring and dot both using HermexSelectionControlColors.selected (Neutral.s950 in light appearance, Neutral.s50 in dark — not a fixed accent), mirroring HermexCheckbox\'s own selected treatment. A group is just multiple Radio instances sharing one selected value in the caller; the component itself only knows its own selected state.',
    whenToUse: 'Use it for exclusive, one-of-many selection. For an independent multi-select fact, use Checkbox instead.',
    props: [
      { name: 'isSelected', type: 'Bool', required: true, desc: 'Whether the center dot is filled.' },
      { name: 'action', type: '(() -> Void)?', desc: 'Omit when a containing row owns the tap — the radio then renders as a non-interactive, accessibility-hidden indicator, mirroring HermexCheckbox\'s own row-owned configuration.' },
      { name: 'label', type: 'String?', desc: 'Optional inline label after the circle.' },
      { name: 'isEnabled', type: 'Bool', default: 'true', desc: 'Dims the control and disables interaction when false.' },
    ],
    a11y: 'With `action`, the control exposes accessibilityAddTraits(.isSelected) when selected, and normal Button semantics otherwise. Without `action`, the identical visual is hidden from VoiceOver, the same row-owned convention Checkbox already follows.',
    render: () => <RadioFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it for exclusive, one-of-many selection.',
      avoidWhen: 'Avoid it for an independent multi-select fact — use Checkbox instead.',
      alternatives: [
        { name: 'Hermes Checkbox', useWhen: 'For an independent multi-select fact rather than mutually exclusive choice.' },
        { name: 'Segmented Control', useWhen: 'For a prominent, always-visible view or filter switch among a few options rather than a list-style choice.' },
        { name: 'Hermes Selection Sheet', useWhen: 'For a long or scrollable option list that should collapse into a sheet instead of occupying a row each.' },
      ],
      adoptionStatus: { state: 'foundation-available', detail: 'Component exists (HermexRadio.swift) with no production call site yet.' },
      useSummary: 'New production primitive; no screen has adopted it yet in this slice.',
      implementationNotes: {
        status: 'Component exists (HermexRadio.swift) with no production call site yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexRadio.swift'],
        notes: [
          'Mirrors HermexCheckbox\'s architecture exactly (DS circle size matches the checkbox box size, same 44pt minimum hit target, same disabled opacity, same component-scoped HermexSelectionControlColors Neutral.s950 / Neutral.s50 selected treatment) with a circular selected/unselected treatment instead of a boolean toggle.',
          'HermexSelectionControlColors\' pairings are contrast-validated, component-scoped: unselectedBorder is Neutral.adaptive(light: Neutral.s500, dark: Neutral.s600), corrected from the retired, under-contrast light Neutral.s400 (#AEAEB1, ~2.1:1) to the validated Neutral.s500 (#8E8E93, >=3:1 against the primary surface, WCAG 1.4.11).',
          'Report only: a single-choice (not allowsMultipleChoices) Bot pending-request question already renders its own largecircle.fill/circle glyph per choice (see Hermes Checkbox) — a plausible future HermexRadio adoption site, not migrated in this slice.',
        ],
      },
      canonicalSymbols: ['HermexRadio'],
      usageExamples: [
        { name: 'Exclusive option row', language: 'swift', code: `HermexRadio(isSelected: selection == .optionA, label: "Option A") {
    selection = .optionA
}` },
      ],
      machineConfigurations: [
        { name: 'Interactive (owns the tap)', props: { action: 'provided' } },
        { name: 'Row-owned indicator', props: { action: 'omitted' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Selection Sheet',
    displayName: 'Selection Sheet',
    description:
      'A caller-presented sheet — `HermexSelectionSheet` (HermexSelectionSheet.swift) — composed entirely from existing foundations: Bottom Sheet for the sheet chrome and, for multi-selection, its own pinned footer for Cancel/Done; single-selection keeps Cancel in TopNav and renders no footer. A scrolling `HermexList` of `ListItem` rows, row-owned visual-only `HermexRadio`/`HermexCheckbox` indicators, and an optional caller-controlled `HermexSearchField` round out the content. The caller owns native `.sheet` presentation, detents, drag indicator, and compact adaptation; Selection Sheet owns only the presented content and local selection lifecycle. Single selection commits immediately on an enabled row tap and dismisses; multi-selection stages taps in a local draft until Done, with Cancel/swipe/Escape/teardown discarding it.',
    whenToUse: 'Use it for a fixed-option single- or multi-selection field, especially a longer or scrollable option list. For a short set that should stay always visible as its own rows, use Radio or Checkbox instead; for a short set as a top-level view switch, use Segmented Control.',
    props: [
      { name: 'selection', type: 'Binding<Value?>', required: true, desc: 'Single-selection initializer: the caller\'s current optional selection. Committed once on an enabled-row tap, then dismissed; disabled rows and Cancel/swipe/Escape/teardown never mutate it. Renders Cancel in TopNav\'s leadingPrimary and no footer.' },
      { name: 'selections', type: 'Binding<Set<Value>>', required: true, desc: 'Multi-selection initializer: seeds a local draft at open time. Row taps toggle the draft only; Done writes the complete draft to this binding once and dismisses; Cancel/swipe/Escape/teardown discard the draft. Renders no TopNav Cancel/Done — both actions move into the Bottom Sheet\'s own footer instead (see footerAxis).' },
      { name: 'footerAxis', type: 'HermexSelectionSheetFooterAxis: .horizontal | .vertical', default: '.horizontal', desc: 'Multi-selection only — arranges the footer\'s Cancel/Done actions. Horizontal orders Cancel then Done, hugging the trailing edge; vertical stacks Done above Cancel, each stretched full width. The single-selection initializer stores .horizontal but never renders a footer at all.' },
      { name: 'options', type: '[HermexSelectionSheetOption<Value>]', required: true, desc: 'Each option\'s value, display title, and enabled state. Disabled options stay visible and announced but never toggle or dismiss.' },
      { name: 'search', type: 'HermexSelectionSheetSearch?', desc: 'Optional. When present, renders the real HermexSearchField above the list; the caller owns the query binding and supplies the currently visible options array — Selection Sheet never filters, debounces, or loads results itself.' },
      { name: 'contentInset', type: '.standard | .none', default: '.standard', desc: 'A closed, semantic choice for the outer horizontal inset applied once to the shared Search/list/empty-state container — never an arbitrary CGFloat. `.standard` is the 16pt standard screen margin (HermesSpacing.s16); `.none` removes it, for a caller that already supplies its own padding (e.g. a pre-padded Card).' },
    ],
    a11y: 'Every row is one ListItem Button target with a 44pt minimum hit area; the Radio/Checkbox indicator is accessibility-hidden so it never duplicates the row\'s own selected/disabled announcement. Initial VoiceOver focus lands on the current selected enabled option, else the first enabled visible option. Cancel and Done stay reachable with keyboard and VoiceOver in either TopNav (single-selection) or the footer (multi-selection); vertical footer order announces Done before Cancel, matching reading/focus order. Escape follows native sheet dismissal and discards an uncommitted multi draft.',
    render: () => <SelectionSheetFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it for a fixed-option single- or multi-selection field, especially a longer or scrollable option list that would not fit as its own rows or a fixed track.',
      avoidWhen: 'Avoid it for a short, always-visible set of choices — use Radio, Checkbox, or Segmented Control instead. Avoid adding caller-owned filtering, remote requests, debounce, pagination, or result loading/error state to the component itself — the caller keeps owning search query, visible options, loading, and errors.',
      alternatives: [
        { name: 'Hermes Radio', useWhen: 'When every option should stay visible as its own row instead of collapsing into a sheet.' },
        { name: 'Hermes Checkbox', useWhen: 'For a short, always-visible independent multi-select list rather than a staged sheet draft.' },
        { name: 'Segmented Control', useWhen: 'For a short, always-visible top-level view or filter switch rather than a form field.' },
        { name: 'Text Input', useWhen: 'For freeform text entry rather than a fixed option list.' },
        { name: 'Bottom Sheet', useWhen: 'When the sheet must configure several independent settings, fields, or controls rather than choose values from one fixed option list — compose Bottom Sheet directly.' },
      ],
      adoptionStatus: { state: 'foundation-available', detail: 'Component exists (HermexSelectionSheet.swift) with no production call site yet.' },
      useSummary: 'New production primitive; no screen has adopted it yet in this slice — zero production Picker/Menu call sites are migrated onto it.',
      implementationNotes: {
        status: 'Component exists (HermexSelectionSheet.swift) with no production call site yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexSelectionSheet.swift'],
        notes: [
          'The caller owns native `.sheet` presentation, detents, drag indicator, compact adaptation, the trigger, option data, and any query/filtering; Selection Sheet dismisses through the environment dismiss action and never wraps itself in a second `.sheet` or overlay mechanism.',
          'Multi-selection\'s footer reuses HermexBottomSheet\'s own existing footer slot and HermesSpacing.s12 footer spacing — Selection Sheet does not become part of Bottom Sheet\'s generic API or add a second sheet mechanism of its own; it only composes the footer that already exists.',
          'Single-selection rows use a noninteractive, accessibility-hidden HermexRadio indicator; multi-selection rows use a noninteractive, accessibility-hidden HermexCheckbox indicator — ListItem owns the only Button action per row via its additive indicator-only selectionChrome seam, so no nested control exists.',
          'Report only: no production call site imports or composes HermexSelectionSheet.swift in this branch; every existing native Picker/Menu call site keeps its current, unmigrated implementation. Migrating one onto Selection Sheet is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexSelectionSheet', 'HermexSelectionSheetOption'],
      usageExamples: [
        { name: 'Single-selection sheet', language: 'swift', code: `HermexSelectionSheet("Model", selection: $model, options: modelOptions)` },
      ],
      machineConfigurations: [
        { name: 'Single selection', props: { selection: 'Binding<Value?>' } },
        { name: 'Multi selection', props: { selections: 'Binding<Set<Value>>', footerAxis: '.horizontal' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Toast',
    displayName: 'Toast',
    whenToUse: 'Use a transient Toast for a one-off confirmation or brief status whose visibility the caller owns — clear it yourself, since there is no auto-dismiss; use Banner instead when the condition remains relevant until resolved (e.g. offline).',
    description:
      'A transient status notice — a dark semantic surface with white icon, message, and optional action — presented via the `hermexToast(isPresented:toast:)` view modifier. Lifecycle stays entirely caller-owned: no internal timer or auto-dismiss.',
    props: [
      { name: 'semantic', type: '.information | .success | .warning | .error', required: true, desc: 'Drives the fixed dark background ramp step and the default icon.' },
      { name: 'message', type: 'Text', required: true, desc: 'The toast\'s message.' },
      { name: 'icon', type: 'String?', desc: 'Overrides the semantic\'s default SF Symbol.' },
      { name: 'isIconDecorative', type: 'Bool', default: 'true', desc: 'Hides the icon from VoiceOver when the message text already announces the same fact.' },
      { name: 'action', type: '{ title: String; handler: () -> Void }?', desc: 'Optional trailing action button: plain white text with a 44pt minimum tap target and no filled capsule, separated from the message by spacing alone.' },
    ],
    a11y: 'Icon, message, and action combine into one accessible element when there is no action; an action present keeps the group\'s children independently focusable (accessibilityElement(children: .contain)).',
    render: () => <ToastFamilyGallery />,
    hermesReference: {
      useWhen: 'Use a Toast for a one-off confirmation or brief status whose visibility the caller owns — bind isPresented and clear it yourself; there is no auto-dismiss.',
      avoidWhen: 'Avoid it when the condition remains relevant until resolved — use Banner instead.',
      alternatives: [
        { name: 'Hermes Banner', useWhen: 'When the condition remains relevant until resolved, rather than a one-off confirmation.' },
      ],
      adoptionStatus: { state: 'foundation-available', detail: 'Component exists (HermexToast.swift) with no production call site yet.' },
      useSummary: 'New production primitive; no screen has adopted it yet in this slice. Distinct from Workspace/Git\'s own GitActionToastOverlay, a separate progress/success state machine that predates this generic primitive.',
      implementationNotes: {
        status: 'Component exists (HermexToast.swift) with no production call site yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexToast.swift'],
        notes: [
          'Presentation (`hermexToast(isPresented:toast:)`) mirrors GitActionToastOverlay\'s established top-anchored, Reduce-Motion-safe transition, so a new caller gets the same feel without hand-rolling it again: it enters by moving down from the top edge combined with opacity (HermesMotion.Bundle.overlayEnter) and exits back toward the top combined with opacity (HermesMotion.Bundle.overlayExit). Reduce Motion drops the directional move and falls back to an opacity-only state change. Visibility itself stays entirely caller-owned — no internal timer.',
          'The trailing action is a plain `Button(action.title) { … }` styled `.foregroundStyle(.white)` with `.buttonStyle(.hermexPressOnly(.compactControl))` and a 44pt minimum tap target — never a filled capsule or a separate neutral-button composition. The catalog gallery demonstrates the same white-on-dark-surface treatment by overriding the generic Toast\'s own background per semantic (Blue.s700/Green.s800/Orange.s800/Red.s700) while leaving its default white icon/message/action colors untouched, since the generic Toast\'s own light-tinted `variant` styles do not match this contract.',
          'Each of the four semantic surfaces resolves to one fixed ramp step: .information to Blue.s700, .success to Green.s800, .warning to Orange.s800, and .error to Red.s700 — with the icon, message, and action content all rendering as white on top of that colored surface, never platform-adaptive text/icon colors.',
        ],
      },
      canonicalSymbols: ['HermexToast', '.hermexToast(isPresented:toast:)'],
      usageExamples: [
        { name: 'Success toast with an undo action', language: 'swift', code: `.hermexToast(isPresented: $isPresented, toast: HermexToast(
    .success,
    message: Text("Copied"),
    action: .init(title: "Undo", handler: undo)
))` },
      ],
      machineConfigurations: [
        { name: 'Information', props: { semantic: '.information' } },
        { name: 'Success', props: { semantic: '.success' } },
        { name: 'Warning', props: { semantic: '.warning' } },
        { name: 'Error', props: { semantic: '.error' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes Tooltip',
    displayName: 'Tooltip',
    description:
      'Anchored explanatory content behind an explicit tap trigger, presented through the native `.popover` path — the same one ContextWindowIndicatorView and GitBranchPickerView already use. Never a hover-only affordance.',
    whenToUse: 'Use it for a short explanatory aside anchored to a specific control. For a persistent, always-visible detail, use Card or Transcript Log Row instead.',
    props: [
      { name: 'trigger', type: '() -> some View', desc: 'The tappable trigger content; `.info(...)` supplies the common "info" glyph trigger.' },
      { name: 'content', type: '() -> some View', desc: 'The popover\'s explanatory content; Dynamic Type-safe (fixedSize(vertical:)), never truncated.' },
      { name: 'accessibilityLabel', type: 'String', default: '"More information"', desc: 'The trigger\'s accessibility label.' },
    ],
    a11y: 'Dismissal is the popover\'s own native recovery path: tap outside, or Escape on a hardware keyboard — never a release-driven gesture.',
    render: () => <TooltipFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it for a short explanatory aside anchored to a specific control.',
      avoidWhen: 'Avoid it for a persistent, always-visible detail — use Card or Transcript Log Row instead.',
      alternatives: [
        { name: 'Card', useWhen: 'For persistent, always-visible detail rather than a tap-triggered aside.' },
        { name: 'Transcript Log Row', useWhen: 'For one collapsed line that expands into longer detail.' },
        { name: 'Hermes Popover Menu', useWhen: 'When the anchored content is a short list of actions to run rather than an explanation.' },
      ],
      adoptionStatus: { state: 'foundation-available', detail: 'Component exists (HermexTooltip.swift) with no production call site yet.' },
      useSummary: 'New production primitive; no screen has adopted it yet in this slice.',
      implementationNotes: {
        status: 'Component exists (HermexTooltip.swift) with no production call site yet.',
        sourcePaths: ['HermesMobile/Features/Shared/HermexTooltip.swift'],
        notes: [
          'Reuses the native `.popover(isPresented:)` pattern ContextWindowIndicatorView and GitBranchPickerView already established, with ContextWindowIndicatorView\'s own `.presentationCompactAdaptation(.none)` (GitBranchPickerView uses `.popover`), rather than inventing a second anchored-presentation convention.',
        ],
      },
      canonicalSymbols: ['HermexTooltip', '.popover(isPresented:)'],
      usageExamples: [
        { name: 'Info-glyph tooltip', language: 'swift', code: `HermexTooltip.info {
    Text("Context window usage resets each session.")
}` },
      ],
      machineConfigurations: [
        { name: 'Default trigger label', props: { accessibilityLabel: 'More information' } },
      ],
      compositionSlots: [
        {
          name: 'trigger', description: 'The tappable trigger content; .info(...) supplies the common "info" glyph trigger.', required: true, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 0, role: 'trigger',
          layout: { placement: 'caller-ordered', axis: 'none', position: 'wherever the caller places the trigger view' },
          overflow: 'not-applicable', interactionOwnership: 'component-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'content', description: 'The popover\'s explanatory content; Dynamic Type-safe, never truncated.', required: true, cardinality: 'one', acceptedContent: ['text', 'generic-view'],
          order: 1, role: 'body-content',
          layout: { placement: 'component-fixed', axis: 'none', position: 'anchored popover, below or beside the trigger' },
          overflow: 'wrap', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermes TopNav',
    displayName: 'TopNav',
    description:
      'A Hermex design-system pattern implemented through native iOS/SwiftUI navigation and toolbar primitives, providing up to two fixed-width action slots on each side (leadingPrimary/leadingSecondary, trailingPrimary/trailingSecondary) around a centered title or custom center content.',
    whenToUse: 'Reach for TopNav when a screen needs custom leading/trailing actions beyond a plain native navigation title — a modal/editor\'s Cancel/Save, or a screen with more than one trailing action. A simple screen with no custom actions can keep a native navigation title instead of composing TopNav at all. Bottom and keyboard toolbars are a separate concern, out of scope here.',
    props: [
      { name: 'title', type: 'string', desc: 'Centered title text. Ignored when `center` is set.' },
      { name: 'center', type: 'ReactNode', desc: 'Custom content overriding the centered title — e.g. a search field or segmented toggle.' },
      { name: 'leadingPrimary', type: 'ReactNode', desc: 'The leading side\'s main action (e.g. Back), closest to the screen edge.' },
      { name: 'leadingSecondary', type: 'ReactNode', desc: 'A second, less prominent leading action, closer to the title.' },
      { name: 'trailingPrimary', type: 'ReactNode', desc: 'The trailing side\'s main action (e.g. Save/Done), closest to the screen edge.' },
      { name: 'trailingSecondary', type: 'ReactNode', desc: 'A second, less prominent trailing action, closer to the title.' },
    ],
    a11y: 'Each slot\'s action keeps its own accessibilityLabel and a ≥44×44pt hit target, however many of the four optional slots are populated. The title renders with accessibilityRole="header" and always truncates (numberOfLines={1}) rather than overlapping the reserved slot areas. Slot order stays semantic: the primary action sits closest to the screen edge on its side, the secondary action closest to the title, on both the leading and trailing side.',
    render: () => <TopNavFamilyGallery />,
    hermesReference: {
      useWhen: 'Reach for TopNav when a screen needs custom leading/trailing actions beyond a plain native navigation title — a modal/editor\'s Cancel/Save, or more than one trailing action.',
      avoidWhen: 'Avoid composing it for a simple screen with no custom leading/trailing actions — keep a plain native navigation title instead.',
      alternatives: [
        { name: 'Native navigation title', useWhen: 'For a simple screen with no custom leading/trailing actions.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only design-system contract (`HermesMobile/Features/Shared/TopNav.swift`); production screens keep their own existing, independent `ToolbarItem`/`.navigationTitle` placements in this branch, not this shared `TopNav: ToolbarContent`. Bottom/keyboard toolbars are a separate, out-of-scope concern.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/TopNav.swift', 'native/components/TopNav/TopNav.tsx'],
        notes: [
          'No production file imports or composes the new TopNav.swift in this branch; every screen\'s leading/trailing/principal toolbar placement is still written directly at its own call site.',
          'A screen with no custom leading/trailing actions (most simple list/detail screens) can keep a plain native navigation title and would never need to compose this component at all.',
          'The retained Kanban `.bottomBar` item and any keyboard accessory toolbar remain separate production concerns with their own anatomy; TopNav documents only the top bar.',
          'The gallery\'s icon-only slot actions compose an adaptive-glass surface as a recommended, caller-chosen composition — TopNav.swift itself gains no new default button style of its own; Bottom Sheet scopes that default at its own composition boundary, not here.',
        ],
      },
      canonicalSymbols: ['TopNav'],
      usageExamples: [
        { name: 'Modal header with Cancel/Save', language: 'swift', code: `.navigationTitle("Edit Profile")
.toolbar {
    TopNav(
        leadingPrimary: { Button("Cancel") { dismiss() } },
        trailingPrimary: { Button("Save") { save() } }
    )
}` },
      ],
      machineConfigurations: [
        { name: 'Title only', props: { title: 'provided' } },
        { name: 'Modal / editor', props: { leadingPrimary: 'Cancel', trailingPrimary: 'Save' } },
      ],
      compositionSlots: [
        {
          name: 'center', description: 'Custom content overriding the centered title — e.g. a search field or segmented toggle.', required: false, cardinality: 'one', acceptedContent: ['generic-view', 'control'],
          order: 0, role: 'center-content',
          layout: { placement: 'component-fixed', axis: 'none', position: 'centered, overriding the title' },
          overflow: 'truncate', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'leadingPrimary', description: 'The leading side\'s main action, closest to the screen edge.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 1, role: 'leading-action',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge, closest to the screen edge' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'leadingSecondary', description: 'A second, less prominent leading action, closer to the title.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 2, role: 'leading-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge, closer to the title' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'trailingPrimary', description: 'The trailing side\'s main action, closest to the screen edge.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 3, role: 'trailing-action',
          layout: { placement: 'component-fixed', axis: 'none', position: 'trailing edge, closest to the screen edge' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'trailingSecondary', description: 'A second, less prominent trailing action, closer to the title.', required: false, cardinality: 'one', acceptedContent: ['control', 'icon'],
          order: 4, role: 'trailing-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'trailing edge, closer to the title' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Skeleton Loading',
    description:
      'A new, foundation-only static, motion-free Skeleton family — explicit text-line, block, circle, and rounded-rectangle shapes, plus `.skeletonPlaceholder()` for when a final view already owns the correct geometry. Production\'s existing loading placeholders (Sessions, Insights, Chat) keep their own independent implementation in this branch, never continuous animated shimmer either way.',
    whenToUse: 'Reach for these static shapes when a loading state should preserve the layout of the content that will replace it (rows, cards, avatars); never introduce continuous animated shimmer into production. For an indeterminate fetch with no known content geometry, reach for Content Unavailable\'s `.loading` variant or a native ProgressView spinner instead.',
    a11y: 'Each shape carries a "Loading" accessibility label; a grouped composition wraps several shapes so they announce once, together, instead of once per shape.',
    render: () => <HermesSkeletonGallery />,
    hermesReference: {
      useWhen: 'Reach for these static shapes when a loading state should preserve the layout of the content that will replace it (rows, cards, avatars).',
      avoidWhen: 'Never introduce continuous animated shimmer into production — use these static shapes instead.',
      alternatives: [
        { name: 'Content Unavailable', useWhen: 'For an indeterminate fetch with no known content geometry — its `.loading` variant is a spinner (backed by native ProgressView), not shape placeholders.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only static Skeleton family; Sessions\', Insights\', and Chat\'s existing content-shaped loading placeholders keep their own independent implementation in this branch, not SkeletonPlaceholder.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/SkeletonPlaceholder.swift',
        ],
        notes: [
          'SessionListComponents.swift, ProviderLimitsCard.swift, and ChatTranscriptSupportingViews.swift each keep their own existing loading-placeholder view in this branch; none imports SkeletonPlaceholder.swift.',
          'The catalog\'s own animated Shimmer component remains available as a distinct catalog/reference-only counterpart (see its own gallery below the static shapes) — it is never a claimed production mapping, and production never adopted it.',
        ],
      },
      canonicalSymbols: ['Skeleton', 'Skeleton.Shape', '.skeletonPlaceholder()'],
      usageExamples: [
        { name: 'Text-line skeleton', language: 'swift', code: `Skeleton(shape: .textLine(maxWidth: 160))` },
      ],
      machineConfigurations: [
        { name: 'Text line', props: { shape: '.textLine' } },
        { name: 'Block', props: { shape: '.block' } },
        { name: 'Circle', props: { shape: '.circle' } },
        { name: 'Rounded rectangle', props: { shape: '.roundedRectangle' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'List / ListItem',
    description:
      'A container plus a configurable row: independently optional leading avatar/icon/status content, rich/multiline title and description, a title-adjacent Tag or accessory, two-zone metadata/footer content, trailing data (+ optional trailing subdata), a custom/independently-interactive trailing accessory, selected/disabled/loading/commit-pending states, an accessibility-label override, and Dynamic Type layout adaptation. Picker Row is removed as a standalone family — a picker is ListItem used with selected, pending, and trailing-checkmark configuration, plus an optional secondary action.',
    whenToUse: 'Reach for ListItem for any row anatomy, including a picker row — there is no separate Picker Row component to reach for instead.',
    props: [
      { name: 'leading', type: 'ReactNode', desc: 'Leading slot — typically an Avatar, Icon, or status indicator.' },
      { name: 'title', type: 'string', required: true, desc: 'The row\'s primary label.' },
      { name: 'titleAccessory', type: 'ReactNode', desc: 'Icon/Tag/custom node placed immediately after the title, on the same line.' },
      { name: 'description / subtitle', type: 'string', desc: 'Secondary line below the title; `subtitle` is the pre-existing alias for the same slot. Mirrors the real native Swift subtitle: Text?.' },
      { name: 'metadata / footer (React Native catalog reconstruction only)', type: 'ReactNode | string', desc: 'A third, lower-priority block; `footer` is the pre-existing alias for the same slot. Catalog-reconstruction-only — native Swift ListItem has no metadata/footer slot.' },
      { name: 'trailingText / trailingSubtext (React Native catalog reconstruction only)', type: 'string', desc: 'Compact right-aligned value(s) before the trailing slot. Catalog-reconstruction-only — native Swift ListItem has no trailingText/trailingSubtext prop; its trailing zone is the trailingAccessory ViewBuilder plus the automatic state-driven trailingIndicator (pending spinner, selected checkmark, or rowIndicatorSystemImage).' },
      { name: 'trailing', type: 'ReactNode', desc: 'Trailing accessory, disclosure chevron, checkmark, or other independently interactive custom node. Mirrors the real native Swift trailingAccessory ViewBuilder.' },
      { name: 'disabled', type: 'boolean', default: 'false', desc: 'Dims the row\'s text and, when pressable, disables the press. Mirrors the real native Swift state.isDisabled.' },
      { name: 'loading (React Native catalog reconstruction only)', type: 'boolean', default: 'false', desc: 'Renders the row\'s slots as Shimmer placeholders inside one SkeletonGroup (one "Loading" announcement, not one per slot); never pressable. Catalog-reconstruction-only, and a different concept from native pending: native Swift ListItem models a single-row pending state with ListItemState.isPending, rendered as one trailing ProgressView — it does not redact the row\'s own slots or group multiple rows under one accessibility announcement. General Swift skeleton-placeholder grouping (unrelated to ListItem) is the .skeletonAnnouncement(label:value:disablesHitTesting:) modifier in SkeletonPlaceholder.swift.' },
      { name: 'hapticFeedbackStyle', type: 'HapticButtonFeedbackStyle?', default: 'nil', desc: 'Opt-in tap feedback for callers preserving an existing haptic contract; nil keeps the row on a plain native Button.' },
      { name: 'contentInset', type: '.standard | .none', default: '.standard', desc: 'A closed, semantic seam for the row\'s own horizontal content inset. `.standard` preserves the current inset every existing caller already gets; `.none` removes it, for a caller that supplies its own boundary padding — Popover Menu\'s own 16pt shell inset composes `.none` so that boundary is never doubled.' },
      { name: 'pressed surface', type: 'ListItemButtonStyle: ButtonStyle', desc: 'A tappable row\'s pressed feedback is a rounded rectangle at ListItemMetrics.cornerRadius, transitioning color/opacity over HermesMotion.Bundle.stateChange (150ms) — never a spatial scale. Unselected/indicator-only rows use a component-scoped adaptive Neutral pressed fill; a standard selected row keeps its selected surface with a contrast-safe pressed adjustment. Disabled and pending rows show no pressed feedback.' },
      { name: 'HermexList default vertical content margin', type: 'CGFloat', default: 'HermesSpacing.s12 (12)', desc: 'Applied once on the shared container via .contentMargins(.vertical, _, for: .scrollContent) — native List selection, refresh, row insets, separators, swipe/context menus, and keyboard/accessibility behavior are otherwise untouched.' },
      { name: 'HermexList.Style', type: '.standard | .compactOverlay', default: '.standard', desc: '.standard is the original, still-default container. .compactOverlay is a plain, transparent, separator-free variant — hidden row separators, compact overlay-appropriate insets, and bounded internal scrolling — for a floating menu that supplies its own card surface/shadow. It is exercised by Popover Menu, not applied to any other production or catalog List in this branch.' },
    ],
    a11y: 'A pressable ListItem exposes one combined accessibilityLabel (title + description, overridable) and accessibilityRole="button"; a disabled or loading row is never pressable. In the React Native catalog reconstruction only, a loading row announces "Loading" once via SkeletonGroup instead of once per Shimmer block — there is no native Swift equivalent. The real native Swift ListItem instead models a pending row with ListItemState.isPending, rendered as a single trailing ProgressView with its own tint; this is a different concept, not a native SkeletonGroup. Layout adapts to Dynamic Type via ordinary text flow rather than fixed heights.',
    render: () => <ListItemFamilyGallery />,
    hermesReference: {
      useWhen: 'Reach for ListItem for any row anatomy, including a picker row — there is no separate Picker Row component to reach for instead.',
      avoidWhen: 'Avoid it for a standalone, self-contained unit sitting beside differently-shaped content — that is a Card; avoid it for a repeating expandable group — that is Accordion List.',
      alternatives: [
        { name: 'Hermes Card', useWhen: 'For one self-contained surface rather than a homogeneous set of peer rows.' },
        { name: 'Accordion List', useWhen: 'When rows repeat as expandable header/body groups.' },
        { name: 'Native List row (production)', useWhen: 'For any current screen — SessionInteractiveRow, BotInboxRow, and the picker sheets keep their own rows today.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'New, foundation-only components; the four picker sheets, SessionInteractiveRow, BotInboxRow, and SessionListView\'s main-menu container each keep their own existing, independent row implementation in this branch, not ListItem or HermexList.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/ListItem.swift',
          'HermesMobile/Features/Shared/HermexList.swift',
          'HermesMobile/Features/Shared/SkeletonPlaceholder.swift',
        ],
        notes: [
          'ListItem.swift itself has no production caller in this branch: every row above — the four picker sheets, SessionInteractiveRow/BotInboxRow, and SessionListView\'s main-menu container — keeps its own existing, independent row implementation.',
          'The React Native catalog reconstruction\'s loading prop (Shimmer placeholders grouped under one SkeletonGroup announcement) is catalog-reconstruction-only — native Swift ListItem has no loading prop and never redacts its own slots. Native Swift ListItem instead models a single-row pending state with ListItemState.isPending, rendered as one trailing ProgressView via its own trailingIndicator — a different concept (one row\'s own indicator, not a multi-row placeholder group). General Swift skeleton-placeholder grouping across unrelated rows (unused by ListItem itself) is the .skeletonAnnouncement(label:value:disablesHitTesting:) modifier in SkeletonPlaceholder.swift.',
          'metadata/footer and trailingText/trailingSubtext are likewise React Native catalog-reconstruction-only slots with no native Swift ListItem equivalent — native ListItem\'s only slots are leading, title, titleAccessory, subtitle, and trailingAccessory, plus its own automatic state-driven trailingIndicator.',
          'ModelPickerSheet.swift, DefaultProfilePickerView.swift, CronJobSkillsPicker.swift, and CronJobConfigurationPickers.swift each still construct their own picker row directly; none imports ListItem.swift in this branch — a future consolidation onto ListItem\'s selected/pending/trailing-checkmark configuration is documented here as a foundation capability, not a completed migration.',
          'SessionListComponents.swift\'s SessionInteractiveRow and Bots\' BotInboxRow both keep their own pre-existing row anatomy, unchanged — neither composes ListItem in this branch.',
          'SessionListView.swift\'s main-menu container does not compose HermexList in this branch; it keeps its own existing native SwiftUI List container.',
          'ListItem exposes an explicit, opt-in hapticFeedbackStyle so a future caller can preserve an existing tap-haptic contract instead of silently losing it to the plain Button ListItem otherwise wraps its action in — documented here as an available foundation capability, with no caller yet since ListItem itself has none.',
          'HermexList applies a default 12pt vertical scroll-content margin (.contentMargins(.vertical, HermesSpacing.s12, for: .scrollContent)) reusing the existing HermesSpacing.s12 value — a foundation capability, not yet applied to any production List.',
          'HermexList\'s .compactOverlay style (hidden separators, .plain list style, transparent scroll background, and a 44pt minimum row height) is the container Popover Menu composes for its own floating action rows — see the Popover Menu entry. .standard stays the unchanged default for every existing caller above.',
          'ListItemContentInset (.standard/.none) and the private ListItemButtonStyle (rounded, non-scaling pressed feedback) are both owned once by ListItem itself, so every composing family — Accordion List, Selection Sheet, Popover Menu, and a ListItem placed inside a Card — inherits the same pressed treatment and inset seam rather than each host inventing its own.',
        ],
      },
      canonicalSymbols: ['ListItem', 'HermexList', 'ListItemState'],
      usageExamples: [
        { name: 'Row with a leading icon', language: 'swift', code: `ListItem(title: Text("GPT-5"), action: { select(.gpt5) }) {
    Image(systemName: "cpu")
}` },
      ],
      machineConfigurations: [
        { name: 'Pending', props: { 'ListItemState.isPending': true } },
        { name: 'Disabled', props: { 'ListItemState.isDisabled': true } },
        { name: 'Compact overlay list', props: { 'HermexList.Style': '.compactOverlay' } },
      ],
      compositionSlots: [
        {
          name: 'leading', description: 'Optional leading generic/icon content, rendered inside the row button\'s combined accessibility label.', required: false, cardinality: 'one', acceptedContent: ['icon', 'generic-view'],
          order: 0, role: 'leading-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge of the row, inside the row button' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'combined-element',
        },
        {
          name: 'title', description: 'The row\'s required primary Text label, inside the row button.', required: true, cardinality: 'one', acceptedContent: ['text'],
          order: 1, role: 'primary-text',
          layout: { placement: 'component-fixed', axis: 'horizontal', position: 'first in the title row, inside the row button' },
          overflow: 'truncate', interactionOwnership: 'none', accessibilityOwnership: 'combined-element',
        },
        {
          name: 'titleAccessory', description: 'Optional icon/display-only Tag/generic view placed immediately after the title, on the same line, inside the row button.', required: false, cardinality: 'one', acceptedContent: ['icon', 'display-only-tag', 'generic-view'],
          order: 2, role: 'inline-accessory',
          layout: { placement: 'component-fixed', axis: 'horizontal', position: 'inline, immediately after the title, inside the row button' },
          overflow: 'clip', interactionOwnership: 'none', accessibilityOwnership: 'combined-element',
        },
        {
          name: 'subtitle', description: 'Optional secondary Text under the title/titleAccessory row, inside the row button.', required: false, cardinality: 'one', acceptedContent: ['text'],
          order: 3, role: 'secondary-text',
          layout: { placement: 'component-fixed', axis: 'none', position: 'below the title/titleAccessory row, inside the row button' },
          overflow: 'truncate', interactionOwnership: 'none', accessibilityOwnership: 'combined-element',
        },
        {
          name: 'trailingAccessory', description: 'Optional independently interactive generic/control/icon content, beside — not inside — the row\'s own tap target.', required: false, cardinality: 'one', acceptedContent: ['icon', 'control', 'generic-view'],
          order: 4, role: 'trailing-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'trailing edge of the row, outside the row\'s own tap target' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Accordion List',
    description:
      'A collection-level expandable ListItem composition with explicit card or cardless appearance, single or multiple expansion, caller-controlled or local state, header-aligned body rows, and four explicit separator strategies.',
    whenToUse:
      'Use it when repeated ListItem groups need expandable bodies, such as a future project-to-sessions hierarchy. Use Transcript Log Row for one compact status line that reveals long detail content, and List / ListItem for non-expandable rows.',
    props: [
      { name: 'appearance', type: 'card | cardless', required: true, desc: 'Required visual surface choice; there is no default. card composes the shared Card component (outlined surface) for exactly 16pt horizontal content padding; cardless adds no Accordion-level horizontal outer padding of its own.' },
      { name: 'separatorStyle', type: 'none | betweenRows | topAndBottom | all', required: true, desc: 'Required separator policy; topAndBottom surrounds the whole group and draws no internal lines. The divider directly under an open header always spans the full available Accordion content width; a divider between two body rows begins at those rows\' own text-content column instead.' },
      { name: 'expansion', type: 'single | multiple; controlled or local', required: true, desc: 'Single permits zero or one open item, collapsing the previously open item when a new one opens; multiple permits any number.' },
      { name: 'header', type: 'ListItem', required: true, desc: 'Whole-row expansion button using label typography and a decorative chevron rendered at the 20pt (medium) icon-size step, one step up from ListItem\'s own 16pt default indicator size.' },
      { name: 'headerLeading', type: 'HeaderLeading?', desc: 'Optional; a compile-safe initializer overload exists where HeaderLeading == EmptyView, so a caller omits this entirely instead of passing an empty placeholder frame. Without it, the header title starts at ListItem\'s own standard content column, and body rows/dividers use no Accordion-owned indentation of their own — with it, header/body/divider alignment is exactly the existing avatar-width-derived geometry.' },
      { name: 'bodyItems', type: 'ListItem[]', required: true, desc: 'Caller-owned body rows aligned to the header title column and rendered in the parent scroll container. Expand/collapse visibly animates (respecting Reduce Motion) instead of an instant mount/unmount.' },
    ],
    a11y:
      'Each header is one button exposing expanded/collapsed state. The chevron is decorative, collapsed body rows leave the focus order, body actions stay independent, and Reduce Motion removes spatial transitions.',
    render: () => <AccordionListFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it when repeated ListItem groups need expandable bodies, such as a future project-to-sessions hierarchy.',
      avoidWhen: 'Avoid it for one compact status line that reveals long detail — use Transcript Log Row; avoid it for simple non-expandable rows — use plain List/ListItem.',
      alternatives: [
        { name: 'Transcript Log Row', useWhen: 'For one compact status line that reveals long detail content.' },
        { name: 'List / ListItem', useWhen: 'For non-expandable rows.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'Available as a reusable Design System component; no production Sessions surface has adopted it yet.',
      usedIn: [],
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/AccordionList.swift',
          'HermesMobile/Features/Shared/ListItem.swift',
          'HermesMobileTests/AccordionListTests.swift',
        ],
        notes: [
          'The component is intentionally data-agnostic and contains no ProjectSummary, SessionSummary, persistence, pagination, or Sessions-list behavior — available in this branch\'s foundation layer, with no production call site.',
          'A future Sessions redesign may compose this component in a separate issue and branch.',
          'Card appearance: exactly 16pt horizontal content padding, from the existing card/spacing token (HermexCardMetrics.contentPadding in Swift; Card\'s own DS_SPACING[800] default in the catalog). The Swift card still composes .hermexCardSurface(.outlined, cornerRadius: HermesRadius.card); the catalog card now composes the shared Card component (surface="outlined") directly, rather than a hand-reconstructed border/background, with Card\'s own default vertical padding zeroed since ListItem rows already own their vertical rhythm.',
          'Cardless appearance: no Accordion-level horizontal outer padding is added on either platform; ListItem\'s own internal row insets are unchanged.',
          'Chevron: the header indicator renders at the next icon-size step up — HermesIconSize.medium / DS_ICON_SIZE.md (20pt) — not ListItem\'s existing 16pt default. Swift ListItem gained a configurable rowIndicatorSize seam (default HermesIconSize.small, preserving every other existing caller) so only the accordion header opts into 20pt.',
          'Dividers: the divider directly under an open header always spans the full available Accordion content width on both platforms. A divider between two body rows instead begins at those rows\' own text-content column — the existing avatar width + header/body gap + ListItem\'s own horizontal inset — rather than the row\'s outer frame. That column is conditional on headerLeading\'s presence: with no leading content, both header and body land on ListItem\'s own standard column instead of the avatar-derived one.',
          'Motion: expand/collapse reuses the existing HermesMotion.Bundle.contentReposition animation and Reduce Motion behavior in Swift. The catalog now visibly animates a section\'s body height/opacity with the existing DS_MOTION_DURATION.base/DS_MOTION_EASING.standard tokens (no new motion token), matching the header chevron\'s own Reduce Motion handling; a collapsed section\'s body stays hidden from the accessibility tree even though it stays mounted for the animation.',
        ],
      },
      canonicalSymbols: ['AccordionList'],
      usageExamples: [
        { name: 'Card appearance, single expansion', language: 'swift', code: `AccordionList(
    items: projects,
    appearance: .card,
    separatorStyle: .topAndBottom,
    expansion: .single($expandedProjectID),
    bodyItems: { project in project.sessions },
    headerTitle: { project in Text(project.name) },
    headerSubtitle: { _ in nil },
    headerAccessibilityLabel: { _ in nil },
    headerIsDisabled: { _ in false },
    headerLeading: { _ in EmptyView() },
    headerTitleAccessory: { _ in EmptyView() },
    bodyItem: { _, session in
        ListItem(title: Text(session.title), action: { open(session) })
    }
)` },
      ],
      machineConfigurations: [
        { name: 'Card appearance', props: { appearance: 'card' } },
        { name: 'Cardless appearance', props: { appearance: 'cardless' } },
      ],
      compositionSlots: [
        {
          name: 'header', description: 'Whole-row expansion button using label typography and a decorative chevron.', required: true, cardinality: 'one', acceptedContent: ['generic-view'],
          order: 0, role: 'header',
          layout: { placement: 'component-fixed', axis: 'none', position: 'top of each section, header row' },
          overflow: 'wrap', interactionOwnership: 'component-owned', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'headerLeading', description: 'Optional leading content; omitted entirely via a compile-safe EmptyView overload rather than an empty placeholder frame.', required: false, cardinality: 'one', acceptedContent: ['generic-view', 'icon'],
          order: 1, role: 'leading-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge of the header row' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'bodyItems', description: 'Caller-owned body rows aligned to the header title column.', required: true, cardinality: 'zero-or-more', acceptedContent: ['generic-view'],
          order: 2, role: 'body-content',
          layout: { placement: 'caller-ordered', axis: 'vertical', position: 'below the header, aligned to the title column when expanded' },
          overflow: 'wrap', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
          ownership: 'The accordion owns expand/collapse animation and divider placement; each body row owns its own content and interaction.',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Transcript Log Row',
    description:
      'An icon slot, a one-line summary, an optional trailing accessory, an optional status word, and a chevron that expands into a scrollable detail body — the real, production-adopted anatomy behind a tool-call log line, the "Thinking" reasoning block, and a bot activity/plan row (TranscriptLogRowView.swift). At ordinary Dynamic Type sizes the accessory sits trailing, before the chevron; at accessibility sizes it moves below the summary/detail. This pre-existing production row keeps its own exact spacing, radius, icon-size, and typography values/APIs; it does not import the new Issue #607 foundation tokens. This catalog\'s specimen mirrors that same production geometry exactly — a 20pt icon slot plus the row\'s own 6pt gap, composing to the real TranscriptLogRowMetrics.bodyIndent (26pt) — documenting this already-production-adopted row as-is.',
    whenToUse: 'Use it for compact transcript activity: one collapsed line with a summary, an optional trailing accessory, and optional status that can expand into a bounded, scrollable detail body; for a persistent always-visible detail, use Card instead.',
    props: [
      { name: 'TranscriptLogRowMetrics.minimumHeight', type: 'CGFloat', default: '32', desc: 'Row height at the default text size.' },
      { name: 'TranscriptLogRowMetrics.bodyIndent', type: 'CGFloat', default: '26', desc: 'Icon column width + gap, so the expanded body indents under the row text.' },
      { name: 'TranscriptLogRowMetrics.bodyWindowHeight', type: 'CGFloat', default: '240', desc: 'Fixed cap the expanded body scrolls inside.' },
    ],
    a11y: 'Tap toggles expand/collapse; a long press on the expanded body copies its content, briefly showing "Copied" before reverting to "Copy". VoiceOver reads "Double tap to show details. Long press to copy." while collapsed, and "Double tap to hide details. Long press to copy." while expanded — each caller supplies its own icon and detail text/accessibility label. The row ignores its own child accessibility semantics for the optional trailing accessory, so a caller that supplies one must fold the accessory\'s meaning into `accessibilityLabel`.',
    render: () => <TranscriptLogRowPreview />,
    hermesReference: {
      useWhen: 'Use it for compact transcript activity — one line of collapsed summary/status, with an optional trailing accessory, that can expand into a bounded, scrollable detail body, with copy-on-long-press.',
      avoidWhen: 'Avoid it for a persistent, always-visible detail — use Card instead. Avoid it for a general independently expandable collection that repeats across a list — use Accordion List.',
      alternatives: [
        { name: 'Card', useWhen: 'For a persistent, always-visible detail rather than collapsed status that expands.' },
        { name: 'Accordion List', useWhen: 'When the expandable row repeats across a list rather than standing alone.' },
      ],
      adoptionStatus: { state: 'production-adopted', detail: 'Pre-existing production component already on master; this branch documents it without changing its implementation.' },
      useSummary: 'TranscriptLogRowView.swift is the real, already-adopted production row: a tool call\'s log line, the "Thinking" reasoning block, and a bot activity/plan row all compose it directly today. This entry documents that same production component, not a separate foundation candidate.',
      usedIn: [
        { screen: 'Conversation', path: 'Sessions → open a conversation', effect: 'A tool call\'s log line and the "Thinking" reasoning block both expand into a detail body, via TranscriptLogRowView.' },
        { screen: 'Bots', path: 'Bots → open a bot conversation', effect: 'A bot\'s activity/plan row (BotPlanRowView) composes the same TranscriptLogRowView.' },
      ],
      implementationNotes: {
        status: ADOPTED_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Chat/TranscriptLogRowView.swift',
        ],
        notes: [
          'ToolCallLogRowView.swift, ReasoningBlockView.swift, and BotActivityViews.swift all compose this pre-existing TranscriptLogRowView directly — the real, unchanged, already-adopted row anatomy, not a foundation candidate awaiting migration.',
          'The geometry facts catalogued under Hermex Radius & Geometry are sourced from this same real, adopted TranscriptLogRowMetrics.',
          'Current-base integration correction (PR #974): current master added an optional generic `accessory` ViewBuilder slot between `icon` and `status` (an `Accessory == EmptyView` convenience initializer keeps callers with no accessory unchanged). At ordinary Dynamic Type sizes it renders trailing, before the chevron; at accessibility sizes it moves below the summary/detail. The row ignores the accessory\'s own child accessibility semantics, so a caller that supplies one must fold its meaning into `accessibilityLabel`.',
        ],
      },
      canonicalSymbols: ['TranscriptLogRowView', 'TranscriptLogRowMetrics'],
      usageExamples: [
        { name: 'Expandable tool-call log line with a trailing accessory', language: 'swift', code: `TranscriptLogRowView(
    summary: "Edited main.swift",
    detail: "Passed",
    isExpanded: isExpanded,
    accessibilityLabel: "Edited main.swift, +12 -4, passed",
    copyText: { fullLogOutput },
    toggleExpansion: { isExpanded.toggle() },
    icon: { Image(systemName: "pencil") },
    accessory: { Text("+12 -4") },
    status: { Text("Passed") },
    expandedBody: { Text(fullLogOutput) }
)` },
      ],
      machineConfigurations: [
        { name: 'Collapsed', props: { expanded: false } },
        { name: 'Expanded', props: { expanded: true } },
      ],
      compositionSlots: [
        {
          name: 'icon', description: 'Caller-supplied leading icon identifying the row kind.', required: true, cardinality: 'one', acceptedContent: ['icon'],
          order: 0, role: 'leading-icon',
          layout: { placement: 'component-fixed', axis: 'none', position: 'leading edge of the collapsed row' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'accessory', description: 'Caller-supplied optional trailing detail, such as an edit\'s "+N -M". At ordinary Dynamic Type sizes it sits trailing, before the chevron; at accessibility sizes it moves below the summary/detail.', required: false, cardinality: 'one', acceptedContent: ['text', 'generic-view'],
          order: 1, role: 'trailing-accessory',
          layout: { placement: 'component-fixed', axis: 'none', position: 'ordinary Dynamic Type sizes: trailing edge of the collapsed row, before the chevron; accessibility sizes: below the summary/detail' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'component-owned',
        },
        {
          name: 'status', description: 'Caller-supplied status word shown in the collapsed row, beside the chevron.', required: true, cardinality: 'one', acceptedContent: ['text', 'generic-view'],
          order: 2, role: 'caption',
          layout: { placement: 'component-fixed', axis: 'none', position: 'trailing edge of the collapsed row, beside the chevron' },
          overflow: 'not-applicable', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'expandedBody', description: 'Caller-supplied content revealed in the scrollable expanded body.', required: true, cardinality: 'one', acceptedContent: ['text', 'generic-view'],
          order: 3, role: 'body-content',
          layout: { placement: 'component-fixed', axis: 'vertical', position: 'expanded body, indented under the row text' },
          overflow: 'scroll', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Composer Toolbar',
    displayName: 'Composer Toolbar',
    description:
      'A shared horizontal composer-toolbar row — `HermexComposerToolbar` (HermexComposerToolbar.swift) — one `ScrollView(.horizontal)` accepting one ordered, zero-or-more arbitrary-content slot (never a typed toolbar-item model or named leading/trailing slots), with an elevated appearance (its own adaptive surface, `HermesRadius.r24` radius, and shadow) and a transparent appearance (leaves the surface to the caller). `HermesSpacing.s8` padding applies on all sides (not only horizontal). Generalized from the current Chat/Bots feature-local `ComposerToolbarScroller`, which keeps its own current behavior unchanged. Owns no composer primary-action (dispatch/interrupt) control or any other composer-domain action.',
    whenToUse: 'Reach for it when a caller needs one horizontally scrollable row of arbitrary secondary content — controls (a model picker, a profile switcher), display-only content (a status Tag/pill), or a mix of both — whose content either fits or overflows the available width, in either an elevated card-like surface or a transparent surface inside an existing container.',
    props: [
      { name: 'appearance', type: '.elevated | .transparent', default: '.elevated', desc: 'Elevated draws Color(.systemBackground), HermesRadius.r24, and the controlElevatedResting shadow; transparent renders none of that chrome.' },
      { name: 'content', type: '@ViewBuilder', required: true, desc: 'One ordered, zero-or-more arbitrary-content slot laid out in one HStack — a generic View, a control (e.g. a Button), or display-only content (e.g. a Tag), mixed freely — never the composer\'s primary dispatch/interrupt control or any other composer-domain type. The toolbar owns horizontal ordering, spacing, scrolling, and fades; each child owns its own semantics, interaction, and minimum hit target.' },
      { name: 'HermexComposerToolbarDivider', type: 'View', desc: 'An explicit, caller-inserted vertical divider between logical control groups — hairline width, HermesSpacing.s24 (24pt) visible height, vertically centered, decorative/accessibility-hidden, scrolls with the row\'s own content. The toolbar never inserts one automatically.' },
    ],
    a11y: 'Edge fades reveal only where content is actually hidden behind that edge, animated with a Reduce-Motion-safe fade that becomes instant under Reduce Motion; the row never dismisses the keyboard on scroll, so taps on toolbar controls stay reliable while typing.',
    render: () => <ComposerToolbarFamilyGallery />,
    hermesReference: {
      useWhen: 'Use it for one horizontally scrollable row of arbitrary caller content — whether it fits or overflows — in an elevated or transparent appearance.',
      avoidWhen: 'Avoid it for the composer\'s primary dispatch/interrupt action or any other composer-domain control — this shared foundation never owns one. Avoid a second scrolling row or a vertical stack — it is exactly one horizontally scrollable row.',
      alternatives: [
        { name: 'Buttons', useWhen: 'For a single standalone action outside a scrolling row.' },
        { name: 'Hermes Selection Sheet', useWhen: 'For a longer option list that should collapse into a sheet rather than sit in a scrolling row.' },
        { name: 'Hermes TopNav', useWhen: 'For fixed leading/trailing navigation actions rather than a scrolling row of secondary controls.' },
      ],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'Available in this branch\'s foundation layer; no production call site exists yet.',
      },
      useSummary: 'A new, foundation-only component; zero production screens use it. The current Chat/Bots feature-local ComposerToolbarScroller (HermesMobile/Features/Chat/ChatComposerToolbarScroller.swift) keeps its own separate, unchanged implementation — migrating it onto this shared foundation is deferred to a separate adoption issue.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Features/Shared/HermexComposerToolbar.swift'],
        notes: [
          'Generalized from ComposerToolbarScroller\'s own layout skeleton in ChatComposerToolbarScroller.swift (one ScrollView(.horizontal) + one HStack, HermesSpacing.s8 item spacing, a 44pt minimum row height, hidden scroll indicators, size-based horizontal bounce, and never dismissing the keyboard on scroll) plus an edge-fades rule modelled on production\'s HorizontalOverflowEdgeFades (HorizontalOverflowEdgeFades.swift, unchanged and still applied via .horizontalOverflowFades(_:) by ChatComposerToolbarScroller.swift and MarkdownRenderer.swift) — the new type is HermexComposerToolbarEdgeFades, with an unreferenced ComposerToolbarEdgeFades typealias; the row now applies HermesSpacing.s8 padding on all sides rather than only horizontal.',
          'Issue #607 round 3/4 correction: the elevated appearance\'s radius is the explicit HermesRadius.r24 token, superseding the earlier HermesRadius.card, and its all-around padding is HermesSpacing.s8, superseding the earlier HermesSpacing.s16 — this catalog reconstruction (HermesComponentFamiliesPreviews.tsx\'s composerToolbarElevated style) now matches both corrected values.',
          'The content slot is one ordered, zero-or-more arbitrary-content slot, not a button-only concept: the DEBUG overlay lab\'s "Elevated, mixed content" specimen and this catalog\'s "Elevated — mixed content" gallery specimen both demonstrate a display-only Tag alongside a real Button in the same row.',
          'Report only: no production call site imports or composes HermexComposerToolbar( in this branch; ChatComposerView.swift and BotChatComposerView.swift keep calling their own existing ComposerToolbarScroller unchanged. Migrating one onto Composer Toolbar is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermexComposerToolbar', 'HermexComposerToolbarDivider'],
      usageExamples: [
        { name: 'Elevated toolbar with mixed content', language: 'swift', code: `HermexComposerToolbar(appearance: .elevated) {
    Button("Model") { showModelPicker() }
    HermexComposerToolbarDivider()
    Tag(label: "Beta", tint: .blue)
}` },
      ],
      machineConfigurations: [
        { name: 'Elevated', props: { appearance: '.elevated' } },
        { name: 'Transparent', props: { appearance: '.transparent' } },
      ],
      compositionSlots: [
        {
          name: 'content',
          description: 'One ordered, zero-or-more arbitrary-content slot the toolbar lays out left-to-right (right-to-left under RTL) in a single horizontally scrolling row.',
          cardinality: 'zero-or-more',
          acceptedContent: ['generic-view', 'control', 'display-only-tag', 'future-component'],
          order: 0, role: 'body-content',
          layout: { placement: 'caller-ordered', axis: 'horizontal', position: 'the toolbar\'s single row, filling its optional elevated/transparent surface' },
          overflow: 'scroll', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
          ownership: 'The toolbar owns horizontal ordering, spacing, scrolling, edge fades, and its own optional surface; each child owns its own semantics, interaction, and minimum hit target.',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Content Unavailable',
    description:
      "A new, foundation-only reusable pattern — Loading, Empty, No results, Error, Unavailable, and Custom variants — intended to eventually replace direct production ContentUnavailableView use. It composes Hermex icon treatment, typography, spacing, and Buttons, with an optional description plus primary and secondary actions. Icon-bearing variants compose Avatar for their identity glyph; the Loading variant renders a plain spinner with an optional description, no icon or title.",
    whenToUse: 'Use it when a screen is loading, has no content, has no search results, cannot load its content, or needs a custom empty/error state with an action.',
    props: [
      { name: 'variant', type: "'loading' | 'empty' | 'noResults' | 'error' | 'unavailable' | 'custom'", required: true, desc: 'Selects the icon/title pairing; loading renders a plain spinner instead of an icon/title.' },
      { name: 'description', type: 'String?', desc: 'Optional secondary line under the title.' },
      { name: 'primaryAction / secondaryAction', type: '{ label: String; onPress: () -> Void }?', desc: 'One action keeps its established secondary emphasis unchanged; both together stack vertically, primary first, with the primary action promoted to the primary hierarchy.' },
      { name: 'layout', type: "'.intrinsic' | '.fullScreen'", default: '.intrinsic', desc: 'Additive placement choice. .intrinsic (default, unchanged) lets ContentUnavailableView center its own content. .fullScreen instead positions the top of the content cluster at roughly one third of the available container height, wrapped in a ScrollView so long content/Dynamic Type can grow rather than clip.' },
    ],
    a11y: 'Icon, title, and description combine into one accessible element; a primary/secondary action is a normal focusable Button, not part of that combined element. The .fullScreen layout changes only placement, not this accessibility grouping.',
    variants: {
      items: [
        { key: 'loading', name: 'Loading', node: <ContentUnavailablePreview variant="loading" /> },
        { key: 'empty', name: 'Empty', node: <ContentUnavailablePreview variant="empty" /> },
        { key: 'no-results', name: 'No results', node: <ContentUnavailablePreview variant="noResults" /> },
        { key: 'error', name: 'Error', node: <ContentUnavailablePreview variant="error" primaryAction /> },
        { key: 'unavailable', name: 'Unavailable', node: <ContentUnavailablePreview variant="unavailable" /> },
        { key: 'custom', name: 'Custom', node: <ContentUnavailablePreview variant="custom" primaryAction secondaryAction /> },
      ],
    },
    states: {
      items: [
        { key: 'no-description', name: 'Without description', node: <ContentUnavailablePreview withDescription={false} /> },
        { key: 'with-actions', name: 'With primary + secondary actions', node: <ContentUnavailablePreview primaryAction secondaryAction /> },
        { key: 'full-screen', name: 'Full-screen placement', node: <ContentUnavailableFullScreenPreview /> },
      ],
    },
    hermesReference: {
      useWhen: 'Use it when a screen is loading, has no content, has no search results, cannot load, or needs a custom empty/error state with an action — the .loading variant is a plain spinner with description.',
      avoidWhen: 'Avoid it for a partial or inline empty section inside otherwise populated content (use body text or a Banner), and for a transient failure while content remains visible (use Toast or Banner).',
      alternatives: [
        { name: 'Native ContentUnavailableView', useWhen: 'For any current production empty/error/no-results state — this is what every screen actually calls today.' },
        { name: 'Skeleton Loading', useWhen: 'When the loading state should preserve the layout of the rows, cards, or avatars that will replace it — Content Unavailable\'s .loading is a plain spinner for unknown geometry.' },
      ],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only pattern; every production screen — including Settings\' pickers, Kanban\'s status/filter empty branch, and Usage\'s loading/error/empty states — keeps calling the native SwiftUI ContentUnavailableView directly in this branch, not HermexContentUnavailable.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Shared/HermexContentUnavailable.swift',
        ],
        notes: [
          'The platform ContentUnavailableView is used directly across 30 production files (68 source references) in the current working tree, including ModelPickerSheet.swift, DefaultProfilePickerView.swift, CronJobSkillsPicker.swift, CronJobConfigurationPickers.swift, KanbanLabView.swift, InsightsView.swift, TasksView.swift, SkillsView.swift, and MemoryView.swift — none imports HermexContentUnavailable.swift. That file/reference count is a descriptive snapshot of the current tree, not an enforced baseline: scripts/hermex_design_system_adoption_audit.py intentionally does not count or restrict native ContentUnavailableView call sites, so a future migration is ordinary issue-driven work, not something this script gates.',
          'HermexAvatar (also new, unadopted) is composed by HermexContentUnavailable\'s own icon-bearing variants for their identity glyph — an internal foundation-layer composition, not a claim about any production picker sheet\'s current icon treatment.',
          'The additive layout prop (.intrinsic default / .fullScreen) is also new and unadopted in this branch — no production screen passes layout: .fullScreen yet. .fullScreen reads the container height via GeometryReader and positions the content cluster at roughly one third of it, wrapped in a ScrollView for Dynamic Type/long-content robustness, instead of ContentUnavailableView\'s own centering.',
        ],
      },
      canonicalSymbols: ['HermexContentUnavailable'],
      usageExamples: [
        { name: 'Empty state with a retry action', language: 'swift', code: `HermexContentUnavailable(
    variant: .empty,
    description: Text("No sessions yet."),
    primaryAction: .init(title: "New Session", handler: createSession)
)` },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Pending Request',
    description:
      'Shared Request Card, block, field, and choice surfaces for questions and approvals that need a response from the user. The pattern composes Request Card, Disclosure/command blocks, fields, choices, and Buttons; approval, denial, clarification, pending, disabled, success, failure, cancellation, and recovery remain domain-owned states.',
    props: [
      { name: 'pendingRequestCardSurface(cornerRadius:)', type: '(CGFloat) -> some View', desc: 'Defined in PendingRequestSurfaces.swift, not HermexCard.swift — a separate, pre-existing function, unconditionally secondarySystemBackground + stroke, deliberately opaque so it always renders above live transcript text. cornerRadius is caller-supplied — 26pt (ChatComposerMetrics.cardCornerRadius) for the Sessions clarification card, a Bot-card-specific value for the Bot card.' },
      { name: 'pendingRequestBlockSurface()', type: '() -> some View', desc: 'The recessed block a question or command sits in, inside a card. Fixed 12pt corner radius.' },
      { name: 'pendingRequestFieldSurface()', type: '() -> some View', desc: 'The free-text response field\'s surface, including its padding. Fixed 14pt corner radius.' },
      { name: 'pendingRequestChoiceSurface(reduceTransparency:)', type: '(Bool) -> some View', desc: 'Opaque when Reduce Transparency is on; regular Adaptive Glass otherwise. Fixed 14pt corner radius on every branch.' },
    ],
    a11y: 'pendingRequestChoiceSurface branches explicitly on Reduce Transparency; the Request Card surface is deliberately opaque so an approval/clarification request never blends into the transcript underneath it.',
    variants: {
      itemsFill: true,
      align: 'left',
      items: [
        { key: 'card', name: 'Request Card surface', node: <View style={recon.prCard}><Text style={recon.prText}>Approve this action?</Text></View> },
        { key: 'block', name: 'Block surface', node: <View style={recon.prBlock}><Text style={recon.prText}>rm -rf build/</Text></View> },
        { key: 'field', name: 'Field surface', node: <View style={recon.prField}><Text style={recon.prText}>Type a response…</Text></View> },
      ],
    },
    states: {
      itemsFill: true,
      align: 'left',
      items: [
        { key: 'choice-glass', name: 'Choice surface — glass', node: <View style={recon.prChoiceGlass}><Text style={recon.prText}>Yes · No</Text></View> },
        { key: 'choice-opaque', name: 'Choice surface — Reduce Transparency', node: <View style={recon.prChoiceOpaque}><Text style={recon.prText}>Yes · No</Text></View> },
      ],
    },
    hermesReference: {
      useWhen: 'Use these shared surfaces (Request Card, block, field, choice) for any new approval/clarification/response surface that needs to read clearly over live transcript text.',
      avoidWhen: 'Avoid these surfaces for content that needs no user response — an informational card is a Section/Settings card. ApprovalRequestOverlay keeps its own separate surface and is not covered here.',
      alternatives: [
        { name: 'Hermes Card', useWhen: 'For a general-purpose surface that does not need to stay unconditionally opaque over live transcript content.' },
      ],
      adoptionStatus: PRODUCTION_ADOPTED_ADOPTION,
      usedIn: [
        { screen: 'Sessions', path: 'Sessions → open a conversation', effect: 'Clarification requests appear above the composer, using pendingRequestCardSurface(cornerRadius:).' },
        { screen: 'Bots', path: 'Bots → open a bot conversation', effect: 'Pending requests appear inline with the transcript, and the bot room composer\'s pending card shares the same pendingRequestCardSurface(cornerRadius:).' },
      ],
      implementationNotes: {
        status: ADOPTED_STATUS,
        sourcePaths: [
          'HermesMobile/Features/Chat/PendingRequestSurfaces.swift',
          'HermesMobile/Features/Chat/ClarificationRequestCard.swift',
          'HermesMobile/Features/Bots/BotPendingRequestCard.swift',
          'HermesMobile/Features/Bots/BotRoomComposerView.swift',
        ],
        notes: [
          'Decision controls belong to production\'s pre-existing .chatDecision(_:) ButtonStyle, not the new, unadopted Buttons family documented in this catalog: PendingRequestSubmitButton uses .chatTactile(.icon), the Bot pending-request card\'s Yes/No/Approve/Deny choices use .chatDecision(.primary/.secondary/.destructive), and the Sessions clarification card\'s choices use .chatTactile(.capsule) — see Buttons for that new (foundation-only) family\'s own accurate status.',
          'ApprovalRequestOverlay.swift does not call pendingRequestCardSurface(cornerRadius:) — its own card surface is implemented separately and is not documented here.',
        ],
      },
      canonicalSymbols: [
        'pendingRequestCardSurface(cornerRadius:)',
        'pendingRequestBlockSurface()',
        'pendingRequestFieldSurface()',
        'pendingRequestChoiceSurface(reduceTransparency:)',
      ],
      usageExamples: [
        { name: 'Clarification card surface', language: 'swift', code: `VStack {
    Text("Which branch should this target?")
}
.pendingRequestCardSurface(cornerRadius: ChatComposerMetrics.cardCornerRadius)` },
      ],
      compositionSlots: [
        {
          name: 'cardContent', description: 'The view pendingRequestCardSurface(cornerRadius:) is applied to.', required: true, cardinality: 'one', acceptedContent: ['generic-view'],
          order: 0, role: 'surface-content',
          layout: { placement: 'caller-ordered', axis: 'none', position: 'fills the modifier\'s host view' },
          overflow: 'clip', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'blockContent', description: 'The view pendingRequestBlockSurface() is applied to — a question or command block.', required: true, cardinality: 'one', acceptedContent: ['generic-view', 'text'],
          order: 1, role: 'surface-content',
          layout: { placement: 'caller-ordered', axis: 'none', position: 'fills the modifier\'s host view' },
          overflow: 'wrap', interactionOwnership: 'none', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'fieldContent', description: 'The view pendingRequestFieldSurface() is applied to — the free-text response field.', required: true, cardinality: 'one', acceptedContent: ['generic-view'],
          order: 2, role: 'surface-content',
          layout: { placement: 'caller-ordered', axis: 'none', position: 'fills the modifier\'s host view' },
          overflow: 'wrap', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
        {
          name: 'choiceContent', description: 'The view pendingRequestChoiceSurface(reduceTransparency:) is applied to — a Yes/No/Approve/Deny choice row.', required: true, cardinality: 'one', acceptedContent: ['control', 'generic-view'],
          order: 3, role: 'surface-content',
          layout: { placement: 'caller-ordered', axis: 'horizontal', position: 'fills the modifier\'s host view' },
          overflow: 'not-applicable', interactionOwnership: 'child-owned', accessibilityOwnership: 'child-owned',
        },
      ],
      compositionConstraints: [],
    },
  },
  {
    id: 'Transcript Activity',
    description:
      'A product pattern for the transcript\'s collapsible activity anatomy — a Turn Summary Disclosure, the Activity Disclosure Row, a grouped-tool-history control, assistant message content, and message metadata — preserving each piece\'s own domain ownership.',
    whenToUse: 'Read it before changing how a transcript turn\'s collapsible pieces relate — a turn\'s summary, tool-call rows, reasoning block, and grouped history; implement any individual row with the pre-existing TranscriptLogRowView (see Transcript Log Row for that component\'s own accurate status).',
    a11y: 'Each composed piece keeps its own accessibility behavior — see Transcript Log Row for expand/collapse semantics and Buttons for the grouped-history control\'s press feedback.',
    render: () => <TranscriptActivityPreview />,
    hermesReference: {
      useWhen: 'Read it before changing how a turn\'s summary, tool-call rows, reasoning block, and grouped history nest; implement any individual row with TranscriptLogRowView.',
      avoidWhen: 'Avoid treating this pattern as its own component to adopt — the real owning component for the row anatomy today is the pre-existing TranscriptLogRowView (see Transcript Log Row for that component\'s own accurate status).',
      alternatives: [
        { name: 'Transcript Log Row', useWhen: 'When you need one collapsible row rather than the whole turn composition.' },
      ],
      adoptionStatus: {
        state: 'partially-adopted',
        detail: 'TranscriptLogRowView.swift (pre-existing) is the adopted Activity Disclosure Row — see Transcript Log Row, itself production-adopted. The group-history control\'s composition through the new (unadopted) Buttons family is the remaining foundation-only piece.',
      },
      useSummary: 'TranscriptLogRowView (pre-existing) is the real, adopted Activity Disclosure Row — see Transcript Log Row. Turn Summary stays a separate component because its semantics, height, and expansion contract differ.',
      usedIn: [
        { screen: 'Conversation', path: 'Sessions → open a conversation', effect: 'Tool-call log lines and the "Thinking" reasoning block compose this pattern through the existing TranscriptLogRowView; a turn\'s summary disclosure uses its own TranscriptTurnFoldRowView.' },
        { screen: 'Bots', path: 'Bots → open a bot conversation', effect: 'A bot\'s grouped tool-activity history composes the same existing TranscriptLogRowView anatomy.' },
      ],
      implementationNotes: {
        status: 'TranscriptLogRowView.swift (pre-existing) is the adopted Activity Disclosure Row — see Transcript Log Row, itself production-adopted.',
        sourcePaths: [
          'HermesMobile/Features/Chat/TranscriptLogRowView.swift',
          'HermesMobile/Features/Chat/TranscriptTurnFolding.swift',
          'HermesMobile/Features/Chat/ToolActivityGroupView.swift',
          'HermesMobile/Features/Chat/ReasoningBlockView.swift',
        ],
        notes: [
          'Domain ownership boundary preserved from the approved specification: this pattern documents composition only — turn-folding logic, message content rendering, and metadata stay owned by their existing production types, not absorbed into a generic view.',
          'The group-history control\'s composition through the new (unadopted) Buttons family is a foundation-only proposal, not a description of ToolActivityGroupView.swift\'s current implementation.',
        ],
      },
      canonicalSymbols: ['TranscriptLogRowView', 'TranscriptTurnFolds', 'ToolActivityGroupView', 'ReasoningBlockView'],
      usageExamples: [
        { name: 'A turn\'s tool-call row composes TranscriptLogRowView directly', language: 'swift', code: `ToolCallLogRowView(call: toolCall)` },
      ],
      machineConfigurations: [
        { name: 'Turn summary disclosure' },
        { name: 'Grouped tool-activity history' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Composer',
    description:
      'A product pattern, not a Card variant, describing the target composition of the composer surface, an input field, Buttons, Tag, Composer Chip, Attachment, Adaptive Glass, and status/validation feedback — Buttons, Tag, and Attachment are new, foundation-only families with no production call site yet (see each entry\'s own status); Composer Chip is a real, production-owned inline subsystem, not a new Hermex component; the composer\'s existing production implementation keeps its own independent pieces.',
    whenToUse: 'Use it to understand the target composition of the composer\'s pieces; text editing, keyboard interaction, draft persistence, attachments, runtime selection, voice input, and send/stop lifecycle stay owned by the Composer pattern, not by any one family it composes.',
    props: [
      {
        name: 'Composer Chip (production subsystem)',
        type: 'ComposerChipToken / ComposerChipRenderer / ComposerChipTextView',
        desc: 'An inline, text-embedded reference chip — a recognized skill, workspace file, bot mention, or quote rendered inline with editable/transcript text — not a standalone HermexComposerChip API. Every reference kind renders through the same uniform, NSTextAttachment-backed chip image; there is no ComposerChipVisualStyle type and no isInteractiveReference property in the current production source (HermesMobile/Features/Chat/ComposerChipRendering.swift).',
      },
    ],
    a11y: 'Each composed family keeps its own accessibility behavior; the composer surface itself adds no additional grouping beyond that.',
    render: () => <ComposerPatternPreview />,
    hermesReference: {
      useWhen: 'Use it to understand the target composition of the composer\'s pieces — text editing, keyboard interaction, draft persistence, attachments, and send/stop lifecycle stay owned by the Composer pattern, not by any one family it composes. Use Composer Chip specifically for a recognized skill, workspace file, bot mention, or quote inline with editable/transcript text.',
      avoidWhen: 'Avoid this pattern for an ordinary field outside the chat composer — that belongs to Text Input, not a Composer-pattern concern. Avoid Composer Chip for a standalone action, destination, status, filter, or attachment outside text — use Buttons, List / ListItem, Tag, or Attachment instead.',
      alternatives: [
        { name: 'Text Input', useWhen: 'For an ordinary single-line field outside the chat composer — Text Input\'s Default/Password/Code wrappers; multiline body text is native TextEditor, not this pattern.' },
        { name: 'Buttons', useWhen: 'For a standalone action rather than an inline text reference.' },
        { name: 'List / ListItem', useWhen: 'For a standalone destination row rather than an inline text reference.' },
        { name: 'Tag', useWhen: 'For a standalone status label rather than an inline text reference.' },
        { name: 'Attachment', useWhen: 'For an attachment shown outside text, rather than an inline chip embedded within it.' },
      ],
      adoptionStatus: {
        state: 'reference-only',
        detail: 'Target architecture only for the composer surface, Buttons, Tag, and Attachment — the composer\'s existing production pieces keep their own current, independent implementation; production migration onto the new foundation components is not part of this branch. Composer Chip is different: it documents the real, already-adopted ComposerChipToken/ComposerChipRenderer/ComposerChipTextView subsystem as it exists today, not a foundation candidate.',
      },
      useSummary: 'Target architecture only: the composer\'s existing production action button, selector buttons, status pills, and attachment strip each keep their own current, independent implementation in this branch — none has migrated onto Buttons, Tag, or Attachment. Composer Chip is the one piece already production-adopted, documented here as it is, not as a proposal.',
      usedIn: [
        { screen: 'Conversation', path: 'Sessions → open a conversation', effect: 'The composer surface hosts text input, attachments, inline chip references, and the send/stop action, using its own existing implementation.' },
      ],
      implementationNotes: {
        status: 'Target architecture: this pattern documents a proposed composition against the composer\'s pre-existing production files; production migration onto the new foundation components is not part of this branch. Composer Chip alone documents real, current production behavior.',
        sourcePaths: [
          'HermesMobile/Features/Chat/ChatComposerPresentation.swift',
          'HermesMobile/Features/Chat/ChatComposerAttachmentStripView.swift',
          'HermesMobile/Features/Chat/ChatComposerTextInputView.swift',
          'HermesMobile/Features/Chat/ComposerChipToken.swift',
          'HermesMobile/Features/Chat/ComposerChipRendering.swift',
          'HermesMobile/Features/Chat/ComposerChipTextView.swift',
        ],
        notes: [
          'Preserves domain ownership from the approved specification: text editing, keyboard interaction, draft persistence, attachments, runtime selection, voice input, and send/stop lifecycle stay owned by the Composer pattern, not moved into generic Card/Button props.',
          'Composer Chip: no ComposerChipVisualStyle type, no isInteractiveReference property, and no accessibilityTraits = .link path exists in ComposerChipRendering.swift today — every reference (skill, workspace file, bot mention, or quote) renders through one uniform baked-image chip (an NSTextAttachment-backed chip image), not a distinct interactive/visual split.',
        ],
      },
      canonicalSymbols: ['ComposerChipToken', 'ComposerChipRenderer', 'ComposerChipTextView'],
      usageExamples: [
        { name: 'Composer Chip bakes a reference into one chip image', language: 'swift', code: `let chipImage = ComposerChipRenderer.image(
    label: token.label,
    icon: token.icon,
    metrics: metrics,
    traits: traitCollection,
    isRightToLeft: false
)` },
      ],
      machineConfigurations: [
        { name: 'Skill reference chip', props: { kind: 'skill' } },
        { name: 'Workspace file reference chip', props: { kind: 'workspaceFile' } },
        { name: 'Bot mention chip', props: { kind: 'botMention' } },
        { name: 'Quote chip', props: { kind: 'quote' } },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Colors',
    displayName: 'Colors',
    description:
      'Semantic colors describe purpose rather than a fixed hex value, so surfaces, text, borders, actions, and status feedback adapt correctly. Product palettes provide the selectable header and project accents.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesColorsGallery />,
    hermesReference: {
      useWhen: 'For text and status colors, use the Apple system Color each catalog role binds to (Color(.label), Color(.secondarySystemBackground), …). For a Hermex component surface or border, reuse the contrast-validated, component-scoped Neutral ramp pairs that already exist — HermexCardColors for card fills, HermexSurfaceBorderColors for borders, HermexSelectionControlColors for selection controls — rather than a raw platform color. Use a HermesColorRamp 500 step for a brand or accent tint, and HermesProductPalette for a header-accent or project-color picker.',
      avoidWhen: 'Avoid consuming a non-500 ramp step in any UI pairing until that pairing has passed contrast validation in light, dark, and Increased Contrast (spec §4.1). Avoid inventing a Hermex semantic-color type — the roles are names for platform colors, not a Swift API.',
      alternatives: [],
      adoptionStatus: {
        state: 'foundation-available',
        detail: 'HermesColorRamp and HermesProductPalette exist and are foundation-available on this branch; zero production call sites import either of them. AppTheme.swift\'s HeaderLogoColor and ProjectCreationSheet\'s project palette both keep their own pre-existing literal hex values — disconnected back from a brief HermesProductPalette dependency (PR #974 issue correction). The semantic color roles are documentation-only bindings to platform colors, not a foundation Swift API — there is no Hermex semantic-color type to adopt.',
      },
      useSummary: 'Foundation-only: HermesColorRamp and HermesProductPalette are defined and available, but no production call site imports either of them in this branch. AppTheme.swift\'s HeaderLogoColor and ProjectCreationSheet\'s project palette both keep their own pre-existing literal hex values. The semantic color roles are documentation-only bindings to platform colors, not a Swift API awaiting adoption.',
      usedIn: [],
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/AppTheme.swift', 'HermesMobile/Config/HermesColor.swift'],
        notes: [
          'HeaderLogoColor\'s 6 presets keep their own pre-existing literal hex values (AppTheme.swift); they do not import HermesColorRamp or HermesProductPalette.',
          'ProjectCreationSheet.swift\'s 8 project accent presets keep their own existing literal hex values in this branch; they do not import HermesColorRamp or HermesProductPalette either.',
          'Status/state colors (e.g. offline banners, selection pills) use Apple\'s own SwiftUI semantic colors directly — Hermex defines no separate status color layer.',
          'Report only: no production call site imports or composes HermesColorRamp/HermesProductPalette in this branch; every existing literal-hex caller keeps its own current values unchanged. Migrating one onto this foundation is scoped to a separate adoption issue, not this slice.',
        ],
      },
      canonicalSymbols: ['HermesColorRamp', 'HermesProductPalette'],
      usageExamples: [
        { name: 'Reading a header-accent foundation value', language: 'swift', code: `let accentHex = HermesProductPalette.headerAccentBlue` },
      ],
      tokenFacts: [
        { name: 'HermesColorRamp.Neutral', value: '500 anchor #8E8E93 (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Gold', value: '500 anchor #FFD700 (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Blue', value: '500 anchor #5B7CFF (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Purple', value: '500 anchor #AF52DE (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Red', value: '500 anchor #FF3B30 (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Green', value: '500 anchor #34C759 (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Orange', value: '500 anchor #FB923C (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Cyan', value: '500 anchor #67E8F9 (11 steps, 50-950)' },
        { name: 'HermesColorRamp.Pink', value: '500 anchor #F472B6 (11 steps, 50-950)' },
        { name: 'HermesProductPalette.headerAccentYellow', value: '#FFD700', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette.headerAccentBlue', value: '#5B7CFF', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette.headerAccentPurple', value: '#AF52DE', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette.headerAccentRed', value: '#FF3B30', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette.headerAccentGreen', value: '#34C759', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette.headerAccentWhite', value: '#FFFFFF', purpose: 'Settings -> Appearance header accent preset.' },
        { name: 'HermesProductPalette project palette', value: '8 presets (projectSky, projectGold, projectRed, projectGreen, projectViolet, projectOrange, projectCyan, projectPink)', purpose: 'Sessions -> Projects -> New Project palette.' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Motion',
    displayName: 'Motion',
    description:
      'Eight named motion patterns pair intent with duration and easing. Reduce Motion shortens or removes movement while preserving the state change.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesMotionReference />,
    hermesReference: {
      useWhen: 'Reach for a named motion pattern (duration + easing) when a new interaction needs a Reduce-Motion-safe, consistent feel.',
      avoidWhen: 'Avoid inlining a duration/easing literal or a one-off spring in a new interaction — pick a named Bundle (feedbackPress, stateChange, contentEnter, contentExit, overlayEnter, overlayExit, contentReposition, scrollFollow) so Reduce Motion behaves consistently.',
      alternatives: [],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only duration/easing scale; production\'s existing ChatMotion and bot-face motion timings keep their own independent literals in this branch, not HermesMotion.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/HermesMotion.swift'],
        notes: [
          'ChatMotion.swift, SessionListComponents.swift, and BotFaceMotion.swift do not reference HermesMotion in this branch; each keeps its own duration/easing literals. A future normalization onto this eight-pattern scale is documented here as a foundation capability, not a completed migration.',
        ],
      },
      canonicalSymbols: ['HermesMotion.Bundle'],
      usageExamples: [
        { name: 'Reduce-Motion-safe press feedback', language: 'swift', code: `withAnimation(HermesMotion.animation(for: HermesMotion.Bundle.feedbackPress)) {
    isPressed = true
}` },
      ],
      tokenFacts: [
        { name: 'HermesMotion.Bundle.feedbackPress', value: '100ms, easeInOut', purpose: '0.975 scale press acknowledgement.' },
        { name: 'HermesMotion.Bundle.stateChange', value: '150ms, easeInOut', purpose: 'color/opacity state change.' },
        { name: 'HermesMotion.Bundle.contentEnter', value: '200ms, easeOut', purpose: 'fade + 8pt slide.' },
        { name: 'HermesMotion.Bundle.contentExit', value: '150ms, easeIn', purpose: 'fade + 8pt slide.' },
        { name: 'HermesMotion.Bundle.overlayEnter', value: '250ms, smooth(extraBounce: 0)', purpose: 'directional fade + edge move, or fade + 0.95 to 1 scale for a centered overlay.' },
        { name: 'HermesMotion.Bundle.overlayExit', value: '200ms, easeIn', purpose: 'directional fade + edge move, or fade + 1 to 0.95 scale for a centered overlay.' },
        { name: 'HermesMotion.Bundle.contentReposition', value: '250ms, smooth(extraBounce: 0)', purpose: 'transform.' },
        { name: 'HermesMotion.Bundle.scrollFollow', value: '200ms, easeOut', purpose: 'keeps newest streaming content in view.' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Radius & Geometry',
    displayName: 'Radius & Geometry',
    description:
      'A seven-step radius scale and semantic aliases shape controls, fields, cards, prominent surfaces, and app chrome. Feature-specific dimensions stay named when they are not reusable radius tokens.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesGeometryGallery />,
    hermesReference: {
      useWhen: 'Reach for the seven-step radius scale and its semantic aliases when a new control, field, card, or chrome surface needs a corner radius.',
      avoidWhen: 'Avoid it for a fully rounded edge — use Capsule() directly. Avoid mapping feature-scoped geometry (ChatComposerMetrics, TranscriptLogRowMetrics, AdaptiveReadableContentWidth) onto a step; those stay named.',
      alternatives: [],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only radius scale (HermesRadius.swift); production\'s composer cards, autocomplete panels, and picker rows keep their own existing corner-radius literals in this branch. The GEOMETRY_FACTS table below documents real, verified numeric facts from their actual (pre-existing or new) source files — a fact table, not an adoption claim for the radius scale itself.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: [
          'HermesMobile/Config/HermesRadius.swift',
        ],
        notes: [
          'ChatComposerPresentation.swift and AdaptiveGlassModifier.swift (both pre-existing) do not reference HermesRadius in this branch; ListItem.swift (new) does — but has no production call site yet (see its own entry).',
          'TranscriptLogRowMetrics (the real, adopted source) and AdaptiveReadableContentWidth remain named, feature-scoped exceptions, not migrated into the numeric scale.',
        ],
      },
      canonicalSymbols: ['HermesRadius'],
      usageExamples: [
        { name: 'Card corner radius', language: 'swift', code: `RoundedRectangle(cornerRadius: HermesRadius.card)` },
      ],
      // Deliberately does not re-list ChatComposerMetrics/TranscriptLogRowMetrics/
      // AdaptiveReadableContentWidth here — those named, feature-scoped exceptions already have
      // their own single machine-readable record in GEOMETRY_FACTS above (rendered by this same
      // entry's own gallery); duplicating their names here would create a second, driftable copy.
      tokenFacts: [
        { name: 'HermesRadius.control', value: 'r8' },
        { name: 'HermesRadius.field', value: 'r12' },
        { name: 'HermesRadius.card', value: 'r16' },
        { name: 'HermesRadius.prominent', value: 'r20' },
        { name: 'HermesRadius.chrome', value: 'r24' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Spacing',
    displayName: 'Spacing',
    description:
      'A 12-step spacing scale controls gaps and padding throughout Hermex, from compact icon spacing to large section separation.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesSpacingGallery />,
    hermesReference: {
      useWhen: 'Reach for the 12-step spacing scale for gaps and padding in any new layout, choosing the step by relationship and hierarchy: s2/s4 for micro/inline spacing (hairline-adjacent gaps, tightest gap between closely related elements); s8 for the gap between related controls in a row or cluster; s12 for compact component padding; s16 for the default card/screen inset; s24 for the gap between major content groups; s32–s64 for section-to-section separation, increasing with how distinct the sections are.',
      avoidWhen: 'Avoid it for component-owned fixed geometry (chart heights, tile widths, icon panels) — those belong to HermesUsageSize or HermesAttachmentSize, not the spacing scale; avoid silently rounding an off-scale value — add a named exception.',
      alternatives: [],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only spacing scale; no production screen reads from HermesSpacing yet in this branch — every existing screen keeps its own current spacing literals.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/HermesSpacing.swift'],
      },
      canonicalSymbols: ['HermesSpacing'],
      usageExamples: [
        { name: 'Default card inset with a related-controls gap', language: 'swift', code: `VStack(spacing: HermesSpacing.s8) {
    content
}
.padding(HermesSpacing.s16)` },
      ],
      tokenFacts: [
        { name: 'HermesSpacing.s0', value: '0', purpose: 'No gap.' },
        { name: 'HermesSpacing.s2', value: '2', purpose: 'Hairline-adjacent tight gap.' },
        { name: 'HermesSpacing.s4', value: '4', purpose: 'Tightest real gap between closely related elements.' },
        { name: 'HermesSpacing.s8', value: '8', purpose: 'Small gap/padding.' },
        { name: 'HermesSpacing.s12', value: '12', purpose: 'Medium padding.' },
        { name: 'HermesSpacing.s16', value: '16', purpose: 'Default card/section padding.' },
        { name: 'HermesSpacing.s20', value: '20', purpose: 'Slightly larger section padding.' },
        { name: 'HermesSpacing.s24', value: '24', purpose: 'Gap between major content groups.' },
        { name: 'HermesSpacing.s32', value: '32', purpose: 'Section-to-section spacing.' },
        { name: 'HermesSpacing.s40', value: '40', purpose: 'Large layout spacing.' },
        { name: 'HermesSpacing.s48', value: '48', purpose: 'Extra-large layout spacing.' },
        { name: 'HermesSpacing.s64', value: '64', purpose: 'Largest spacing primitive; values above this remain layout/component geometry.' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Shadow',
    displayName: 'Shadow',
    description:
      'Eight elevation roles distinguish resting and pressed controls, popovers, composer chrome, and overlays. Some roles adjust their opacity between light and dark appearance.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesShadowGallery />,
    hermesReference: {
      useWhen: 'Reach for a named elevation role for a new resting/pressed control, popover, composer chrome, or overlay surface.',
      avoidWhen: 'Avoid inlining a radius/opacity/offset literal; if none of the eight roles fits, add a named role. Avoid any shadow on an Outlined Card, which is documented as no-elevation.',
      alternatives: [],
      adoptionStatus: FOUNDATION_AVAILABLE_ADOPTION,
      useSummary: 'A new, foundation-only elevation-role scale; production\'s composer chrome, overlays, popovers, and App Icon previews keep their own existing shadow literals in this branch, not HermesShadow.',
      implementationNotes: {
        status: FOUNDATION_ONLY_STATUS,
        sourcePaths: ['HermesMobile/Config/HermesShadow.swift'],
        notes: [
          'controlElevatedResting/Pressed and chrome resolve their opacity per light/dark appearance; the other five roles fix one opacity literal for both — a fact about this new token\'s own design, not a claim about any production call site.',
        ],
      },
      canonicalSymbols: ['HermesShadow', '.hermesShadow(_:)'],
      usageExamples: [
        { name: 'Applying a named elevation role', language: 'swift', code: `view.hermesShadow(.controlElevatedResting)` },
      ],
      tokenFacts: [
        { name: 'HermesShadow.none', value: 'opacity 0, radius 0' },
        { name: 'HermesShadow.controlSubtleResting', value: 'opacity 0.12, radius 4, y1' },
        { name: 'HermesShadow.controlSubtlePressed', value: 'opacity 0.06, radius 1, y0' },
        { name: 'HermesShadow.controlElevatedResting', value: 'light 0.18 / dark 0.32, radius 16, y8' },
        { name: 'HermesShadow.controlElevatedPressed', value: 'light 0.10 / dark 0.18, radius 8, y3' },
        { name: 'HermesShadow.popover', value: 'opacity 0.14, radius 12, y4' },
        { name: 'HermesShadow.chrome', value: 'light 0.12 / dark 0.28, radius 14, y6' },
        { name: 'HermesShadow.overlay', value: 'opacity 0.22, radius 18, y12' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
  {
    id: 'Hermex Iconography',
    displayName: 'Iconography',
    description:
      'Hermex uses SF Symbols for navigation, actions, status, and content cues. Browse the visual inventory by symbol name; implementation traces remain secondary.',
    tokenGallery: true,
    fullWidthLabel: 'Tokens',
    render: () => <HermesIconReference />,
    hermesReference: {
      useWhen: 'Reach for SF Symbols for any navigation/action/status/content glyph; reach for the named HermesIconSize scale and its Typography/Avatar pairing sets when sizing a new icon consistently.',
      avoidWhen: 'Avoid a literal point size on a new SF Symbol — pick a HermesIconSize step through its Typography or Avatar pairing set. Avoid a custom image asset where an SF Symbol exists.',
      alternatives: [],
      adoptionStatus: {
        state: 'partially-adopted',
        detail: 'SF Symbol usage itself: adopted, pre-existing, and unrelated to this branch. HermesIconSize (the named size scale): foundation-only, no production caller yet.',
      },
      useSummary: 'SF Symbols themselves (a native platform feature, not a Hermex addition) genuinely appear throughout every main section. HermesIconSize — the new named five-step size scale documented below — is foundation-only, with no production call site yet.',
      usedIn: [
        { screen: 'Sessions and Chat', effect: 'Navigation, message actions, composer controls, and transcript status use SF Symbols, each screen choosing its own point size.' },
        { screen: 'Bots and Tasks', effect: 'Bot artifacts, pending requests, task status, and configuration actions use SF Symbols, each screen choosing its own point size.' },
        { screen: 'Settings and Workspace', effect: 'Settings rows, server controls, files, and Git actions use SF Symbols, each screen choosing its own point size.' },
      ],
      implementationNotes: {
        status: 'SF Symbol usage itself: adopted, pre-existing, and unrelated to this branch. HermesIconSize (the named size scale): foundation-only, no production caller yet.',
        sourcePaths: ['HermesMobile/Config/HermesSpacing.swift'],
        notes: [
          'The inventory is deduplicated by final SF Symbol name.',
          'Literal counts, computed expressions, source sites, and trace methods remain available from hermesIconInventory.generated.json and hermesIconComputedSiteTrace.generated.json.',
          'The browser grid loads the checked-in simulator-rendered PNG baseline for each symbol; "Glyph unavailable in browser" is only an error-only fallback shown when a tile\'s asset is missing or fails to load, and regenerating that baseline is a separate, explicit `npm run generate:icons` step.',
          'A five-step default icon-size scale (HermesIconSize, HermesMobile/Config/HermesSpacing.swift) is defined in this branch\'s foundation layer alongside two semantic pairing sets — Typography pairing (which AppFont.Role text an icon size sits beside inline) and Avatar pairing (which Avatar diameter an icon size sits inside, at the approved pairing: 32pt avatar → 20pt icon, 40pt avatar → 24pt icon, 48pt avatar → 32pt icon) — but no production call site reads HermesIconSize yet; each existing SF Symbol call site still picks its own literal point size.',
        ],
      },
      canonicalSymbols: ['HermesIconSize', 'HermesIconSize.Typography', 'HermesIconSize.Avatar'],
      usageExamples: [
        { name: 'Sizing an icon beside body text', language: 'swift', code: `Image(systemName: "paperclip")
    .font(.system(size: HermesIconSize.small))` },
      ],
      tokenFacts: [
        { name: 'HermesIconSize.xs', value: '12pt', purpose: 'Compact pairing: caption, footnote, caption2, mono12.' },
        { name: 'HermesIconSize.small', value: '16pt', purpose: 'Standard pairing: subheadline, body, label.' },
        { name: 'HermesIconSize.medium', value: '20pt', purpose: 'Prominent pairing: headline, title3.' },
        { name: 'HermesIconSize.large', value: '24pt', purpose: 'Title pairing: title2, title.' },
        { name: 'HermesIconSize.extraLarge', value: '32pt', purpose: 'Standalone feature/empty-state icons, not paired beside inline text.' },
        { name: 'HermesIconSize.Avatar.small', value: '32pt avatar -> 20pt icon' },
        { name: 'HermesIconSize.Avatar.medium', value: '40pt avatar -> 24pt icon' },
        { name: 'HermesIconSize.Avatar.large', value: '48pt avatar -> 32pt icon' },
      ],
      compositionSlots: [],
      compositionConstraints: [],
    },
  },
];

export const hermesNav: NavGroup<HermesSectionId>[] = [
  {
    label: 'Foundations',
    ids: ['Hermex Colors', 'Hermex Spacing', 'Hermex Typography', 'Hermex Font', 'Hermex Motion', 'Hermex Radius & Geometry', 'Hermex Shadow', 'Hermex Iconography'],
  },
  {
    label: 'Materials',
    ids: ['Adaptive Glass'],
  },
  {
    label: 'Native iOS',
    ids: ['Hermes TopNav'],
  },
  {
    label: 'Components',
    // Alphabetized in the sidebar and main column by each entry's own visible display name (see
    // `alphabetizeByLabel` on `NavGroup`) — this declared order is the Hermes-owned family grouping
    // only (see the nav-order test in hermes-catalog.test.mjs), not the rendered order. Search
    // joined this group once its `.hermexSearch` foundation wrapper shipped over native
    // `.searchable` — it moved out of Native iOS even though production hasn't adopted the wrapper
    // yet, and stayed here once that wrapper became the custom HermexSearchField/.hermexSearch
    // foundation, while native `.searchable` remains a valid, production-used control (see Search's own
    // adoptionStatus for the truthful, zero-adoption detail). Text Input
    // joined the same way once its three HermexTextField/HermexSecureField/HermexCodeInput
    // foundation wrappers shipped over native TextField/SecureField/a single numeric TextField — see
    // Text Input's own adoptionStatus for the same truthful, zero-adoption detail.
    alphabetizeByLabel: true,
    ids: [
      'Hermes Avatar', 'Hermes Card', 'Attachment', 'Hermes Banner', 'Hermes Toast', 'Row Divider', 'Tag',
      'Search', 'Text Input', 'Hermes Selection Sheet', 'Hermes Tooltip', 'Segmented Control',
      'Buttons', 'Hermes Checkbox', 'Hermes Radio', 'Skeleton Loading', 'List / ListItem', 'Accordion List', 'Transcript Log Row',
      'Composer Toolbar', 'Bottom Sheet', 'Hermes Dialog', 'Hermes Popover Menu',
    ],
  },
  {
    label: 'Patterns',
    ids: ['Content Unavailable', 'Pending Request', 'Transcript Activity', 'Composer'],
  },
];

// ─── Machine-readable manifest (AI/tool discovery surface) ──────────────────
// Directly discoverable inside the catalog itself — rendered through HermesOverview's own
// "Machine-readable manifest" disclosure, so it never requires leaving the default route or the
// approved five-group sidebar taxonomy for a dedicated nav entry. Built live from hermesSections/
// hermesNav via buildHermesManifestEnvelope() (itself a thin wrapper around the shared
// buildComponentManifest()), so it can never drift out of sync with the human-readable catalog
// above it. Unlike the retained template's own component-only Manifest page, this one always
// includes token galleries so every Foundations token group survives into the JSON too — a tool
// consuming only components/patterns would otherwise silently miss the whole token layer.
const hermesManifestStyles = StyleSheet.create({
  box: { maxHeight: 480, overflow: 'hidden' },
  text: { fontSize: 11, fontFamily: 'Menlo', color: '#1c1c1e', lineHeight: 15 },
});

function HermesManifestJSON() {
  const json = JSON.stringify(buildHermesManifestEnvelope(hermesSections, hermesNav), null, 2);
  return (
    <View style={hermesManifestStyles.box}>
      <Text selectable style={hermesManifestStyles.text}>
        {json}
      </Text>
    </View>
  );
}

export function HermesManifest() {
  return (
    <HermesOverviewImplementationDetails
      meta={{
        implementationNotes: {
          status:
            'Machine-readable manifest, built live from this catalog\'s own SectionDef data — every Foundations token gallery plus every Materials/Native iOS/Components/Patterns entry, each with its own useWhen/avoidWhen/alternatives/adoptionStatus, for tool/agent consumption.',
          sourcePaths: ['design-system-catalog/native/catalog/manifest.ts', 'design-system-catalog/native/catalog/hermes/hermesSections.tsx'],
        },
      }}
      implementationContent={<HermesManifestJSON />}
    />
  );
}
