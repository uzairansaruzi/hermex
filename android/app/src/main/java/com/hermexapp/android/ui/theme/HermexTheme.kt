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
    val Surface1Dark = Color(0xFF1C1C1E) // cards, composer, thinking blocks
    val Surface2Dark = Color(0xFF2C2C2E) // user bubbles, chips
    val Surface3Dark = Color(0xFF3A3A3C) // circular buttons, send circle
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
)

val LocalHermexPalette = staticCompositionLocalOf {
    HermexPalette(
        accent = HermexColors.Gold,
        canvas = HermexColors.Black,
        card = HermexColors.Surface1Dark,
        bubble = HermexColors.Surface2Dark,
        control = HermexColors.Surface3Dark,
        textSecondary = HermexColors.TextSecondaryDark,
        destructive = HermexColors.RedDark,
        warning = HermexColors.OrangeDark,
        success = HermexColors.GreenDark,
        pillBackground = HermexColors.White,
        pillForeground = HermexColors.Black,
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

/** iOS-like continuous rounding: large radii everywhere. */
private val HermexShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(28.dp),
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

@Composable
fun HermexTheme(choice: ThemeChoice = ThemeChoice.SYSTEM, content: @Composable () -> Unit) {
    val dark = when (choice) {
        ThemeChoice.SYSTEM -> isSystemInDarkTheme()
        ThemeChoice.LIGHT -> false
        ThemeChoice.DARK -> true
    }

    val palette = if (dark) {
        HermexPalette(
            accent = HermexColors.Gold,
            canvas = HermexColors.Black,
            card = HermexColors.Surface1Dark,
            bubble = HermexColors.Surface2Dark,
            control = HermexColors.Surface3Dark,
            textSecondary = HermexColors.TextSecondaryDark,
            destructive = HermexColors.RedDark,
            warning = HermexColors.OrangeDark,
            success = HermexColors.GreenDark,
            pillBackground = HermexColors.White,
            pillForeground = HermexColors.Black,
        )
    } else {
        HermexPalette(
            accent = Color(0xFFB8960B),
            canvas = HermexColors.White,
            card = HermexColors.Surface1Light,
            bubble = HermexColors.Surface2Light,
            control = HermexColors.Surface3Light,
            textSecondary = HermexColors.TextSecondaryLight,
            destructive = HermexColors.RedLight,
            warning = HermexColors.OrangeLight,
            success = HermexColors.GreenLight,
            pillBackground = HermexColors.Black,
            pillForeground = HermexColors.White,
        )
    }

    androidx.compose.runtime.CompositionLocalProvider(LocalHermexPalette provides palette) {
        MaterialTheme(
            colorScheme = if (dark) DarkScheme else LightScheme,
            shapes = HermexShapes,
            typography = HermexTypography,
            content = content,
        )
    }
}
