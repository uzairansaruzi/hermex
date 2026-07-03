package com.hermex.app.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Hermex palette, mirrored from the iOS app's semantic system colors so both
 * platforms share one visual identity: monochrome surfaces, the gold Hermes
 * logo color, iOS-blue accents, and iOS status colors.
 */
object HermexColors {
    // Brand
    val HermesGold = Color(0xFFFFD700)

    // iOS accent blue (light / dark variants)
    val AccentBlueLight = Color(0xFF007AFF)
    val AccentBlueDark = Color(0xFF0A84FF)

    // iOS system backgrounds
    val BackgroundLight = Color(0xFFFFFFFF)
    val BackgroundDark = Color(0xFF000000)
    val SecondaryBackgroundLight = Color(0xFFF2F2F7)
    val SecondaryBackgroundDark = Color(0xFF1C1C1E)
    val TertiaryFillLight = Color(0xFFE4E4E9)
    val TertiaryFillDark = Color(0xFF2C2C2E)

    // iOS labels
    val LabelLight = Color(0xFF000000)
    val LabelDark = Color(0xFFFFFFFF)
    val SecondaryLabelLight = Color(0xFF8A8A8E)
    val SecondaryLabelDark = Color(0xFF98989F)

    // iOS separators (flattened, opaque approximations)
    val SeparatorLight = Color(0xFFC6C6C8)
    val SeparatorDark = Color(0xFF38383A)

    // User chat bubble: systemGray6 (light) / systemGray3 (dark)
    val BubbleLight = Color(0xFFF2F2F7)
    val BubbleDark = Color(0xFF48484A)

    // Status colors (iOS light / dark)
    val SuccessLight = Color(0xFF34C759)
    val SuccessDark = Color(0xFF30D158)
    val WarningLight = Color(0xFFFF9500)
    val WarningDark = Color(0xFFFF9F0A)
    val ErrorLight = Color(0xFFFF3B30)
    val ErrorDark = Color(0xFFFF453A)
}
