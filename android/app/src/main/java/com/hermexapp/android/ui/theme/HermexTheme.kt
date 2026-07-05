package com.hermexapp.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hermexapp.android.config.ThemeChoice

/**
 * The Hermex look, matched to the iOS app: pure-black canvas, iOS system-gray
 * surfaces, and the gold Header Logo Color accent (`HeaderLogoColor.defaultHex`
 * = #FFD700 in AppTheme.swift). Light mode mirrors iOS light system colors.
 */
object HermexColors {
    val Gold = Color(0xFFFFD700)

    // iOS dark system palette.
    val Black = Color(0xFF000000)
    val Surface1Dark = Color(0xFF1C1C1E) // cards, composer, thinking blocks (systemGray6)
    val Surface2Dark = Color(0xFF2C2C2E) // chips, secondary containers (systemGray5)
    val UserBubbleDark = Color(0xFF48484A) // iOS user message bubble (systemGray3)
    val Surface3Dark = Color(0xFF3A3A3C) // circular buttons, send circle (systemGray4)
    val TextSecondaryDark = Color(0xFF8E8E93)
    val RedDark = Color(0xFFFF453A)
    val OrangeDark = Color(0xFFFF9F0A) // "Paused" badge
    val GreenDark = Color(0xFF32D74B)

    // iOS light system palette.
    val White = Color(0xFFFFFFFF)
    val Surface1Light = Color(0xFFF2F2F7)
    val Surface2Light = Color(0xFFE9E9EB)
    val Surface3Light = Color(0xFFD1D1D6)
    val TextSecondaryLight = Color(0xFF6D6D72)
    val RedLight = Color(0xFFFF3B30)
    val OrangeLight = Color(0xFFFF9500)
    val GreenLight = Color(0xFF34C759)
}

/** Non-Material roles the iOS design needs by name. */
data class HermexPalette(
    val accent: Color,
    val canvas: Color,
    val card: Color,
    val bubble: Color,
    val control: Color,
    val textSecondary: Color,
    val destructive: Color,
    val warning: Color,
    val success: Color,
    /** The "✎ Chat" pill: white-on-black in dark mode, black-on-white in light. */
    val pillBackground: Color,
    val pillForeground: Color,
    /** iOS inset-grouped list surfaces (Insights): white cards on a gray canvas
     *  in light mode; #1C1C1E cards on pure black in dark. Inverts the plain
     *  `canvas`/`card` relationship used by non-grouped screens. */
    val groupedCanvas: Color,
    val groupedCard: Color,
)

val LocalHermexPalette = staticCompositionLocalOf {
    HermexPalette(
        accent = HermexColors.Gold,
        canvas = HermexColors.Black,
        card = HermexColors.Surface1Dark,
        bubble = HermexColors.UserBubbleDark,
        control = HermexColors.Surface3Dark,
        textSecondary = HermexColors.TextSecondaryDark,
        destructive = HermexColors.RedDark,
        warning = HermexColors.OrangeDark,
        success = HermexColors.GreenDark,
        pillBackground = HermexColors.White,
        pillForeground = HermexColors.Black,
        groupedCanvas = HermexColors.Black,
        groupedCard = HermexColors.Surface1Dark,
    )
}

private val DarkScheme = darkColorScheme(
    primary = HermexColors.Gold,
    onPrimary = HermexColors.Black,
    background = HermexColors.Black,
    onBackground = HermexColors.White,
    surface = HermexColors.Black,
    onSurface = HermexColors.White,
    surfaceVariant = HermexColors.Surface1Dark,
    onSurfaceVariant = HermexColors.TextSecondaryDark,
    secondaryContainer = HermexColors.Surface2Dark,
    onSecondaryContainer = HermexColors.White,
    primaryContainer = HermexColors.Surface2Dark,
    onPrimaryContainer = HermexColors.White,
    tertiary = HermexColors.OrangeDark,
    error = HermexColors.RedDark,
    outline = HermexColors.Surface3Dark,
)

private val LightScheme = lightColorScheme(
    primary = Color(0xFFB8960B), // gold, darkened for light-mode contrast
    onPrimary = HermexColors.White,
    background = HermexColors.White,
    onBackground = HermexColors.Black,
    surface = HermexColors.White,
    onSurface = HermexColors.Black,
    surfaceVariant = HermexColors.Surface1Light,
    onSurfaceVariant = HermexColors.TextSecondaryLight,
    secondaryContainer = HermexColors.Surface2Light,
    onSecondaryContainer = HermexColors.Black,
    primaryContainer = HermexColors.Surface2Light,
    onPrimaryContainer = HermexColors.Black,
    tertiary = HermexColors.OrangeLight,
    error = HermexColors.RedLight,
    outline = HermexColors.Surface3Light,
)

/**
 * iOS-derived corner radii (points = dp), mapped to how each token is used:
 *  - extraSmall 10 → icon tiles / small badges (InsightsView icon tile = 10)
 *  - small 14      → assistant/status cards, search & composer text fields
 *  - medium 20     → chat user message bubble (MessageBubbleView = 20)
 *  - large 18      → cards & sections (SettingsView card = 18)
 *  - extraLarge 22 → composer container (ChatComposerView = 22)
 * Non-monotonic on purpose: iOS cards (18) are less round than user bubbles (20).
 */
private val HermexShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(18.dp),
    extraLarge = RoundedCornerShape(22.dp),
)

private val HermexTypography = Typography().let { base ->
    base.copy(
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.Bold),
        headlineMedium = base.headlineMedium.copy(fontWeight = FontWeight.Bold),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.Bold, fontSize = 22.sp),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold, fontSize = 16.sp),
    )
}

/** Parses a `#RRGGBB` hex to a Compose [Color], falling back to gold. */
fun accentColorFromHex(hex: String): Color = runCatching {
    Color(android.graphics.Color.parseColor(hex))
}.getOrDefault(HermexColors.Gold)

@Composable
fun HermexTheme(
    choice: ThemeChoice = ThemeChoice.SYSTEM,
    accent: Color = HermexColors.Gold,
    content: @Composable () -> Unit,
) {
    val dark = when (choice) {
        ThemeChoice.SYSTEM -> isSystemInDarkTheme()
        ThemeChoice.LIGHT -> false
        ThemeChoice.DARK -> true
    }

    val palette = if (dark) {
        HermexPalette(
            accent = accent,
            canvas = HermexColors.Black,
            card = HermexColors.Surface1Dark,
            bubble = HermexColors.UserBubbleDark,
            control = HermexColors.Surface3Dark,
            textSecondary = HermexColors.TextSecondaryDark,
            destructive = HermexColors.RedDark,
            warning = HermexColors.OrangeDark,
            success = HermexColors.GreenDark,
            pillBackground = HermexColors.White,
            pillForeground = HermexColors.Black,
            groupedCanvas = HermexColors.Black,
            groupedCard = HermexColors.Surface1Dark,
        )
    } else {
        HermexPalette(
            accent = accent,
            canvas = HermexColors.White,
            card = HermexColors.Surface1Light,
            bubble = HermexColors.Surface1Light, // iOS user bubble light = systemGray6 (#F2F2F7)
            control = HermexColors.Surface3Light,
            textSecondary = HermexColors.TextSecondaryLight,
            destructive = HermexColors.RedLight,
            warning = HermexColors.OrangeLight,
            success = HermexColors.GreenLight,
            pillBackground = HermexColors.Black,
            pillForeground = HermexColors.White,
            groupedCanvas = HermexColors.Surface1Light, // #F2F2F7 canvas
            groupedCard = HermexColors.White,            // white cards
        )
    }

    androidx.compose.runtime.CompositionLocalProvider(LocalHermexPalette provides palette) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme.copy(primary = accent) else LightScheme.copy(primary = accent),
            shapes = HermexShapes,
            typography = HermexTypography,
            content = content,
        )
    }
}
