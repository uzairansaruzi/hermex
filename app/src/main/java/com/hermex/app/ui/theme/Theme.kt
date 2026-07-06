package com.hermex.app.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat

/**
 * Colors that have no Material role but are core to the Hermex identity
 * shared with the iOS app: the gold logo/avatar color, iOS status colors,
 * and the monochrome (black-on-white / white-on-black) primary actions used
 * by the Chat FAB and the composer send button.
 */
@Immutable
data class HermexExtendedColors(
    val themeGold: Color,
    val success: Color,
    val warning: Color,
    val monochrome: Color,
    val onMonochrome: Color,
)

val LocalHermexColors = staticCompositionLocalOf {
    HermexExtendedColors(
        themeGold = HermexColors.HermesGold,
        success = HermexColors.SuccessLight,
        warning = HermexColors.WarningLight,
        monochrome = HermexColors.LabelLight,
        onMonochrome = HermexColors.BackgroundLight,
    )
}

private val DarkExtendedColors = HermexExtendedColors(
    themeGold = HermexColors.HermesGold,
    success = HermexColors.SuccessDark,
    warning = HermexColors.WarningDark,
    monochrome = HermexColors.LabelDark,
    onMonochrome = HermexColors.BackgroundDark,
)

private val LightExtendedColors = HermexExtendedColors(
    themeGold = HermexColors.HermesGold,
    success = HermexColors.SuccessLight,
    warning = HermexColors.WarningLight,
    monochrome = HermexColors.LabelLight,
    onMonochrome = HermexColors.BackgroundLight,
)

private val DarkColorScheme = darkColorScheme(
    primary = HermexColors.AccentBlueDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF0A2E52),
    onPrimaryContainer = Color(0xFFB8D8FF),
    secondary = HermexColors.SecondaryLabelDark,
    onSecondary = HermexColors.BackgroundDark,
    secondaryContainer = HermexColors.BubbleDark,
    onSecondaryContainer = HermexColors.LabelDark,
    tertiary = HermexColors.WarningDark,
    onTertiary = Color.Black,
    tertiaryContainer = Color(0xFF3A2A12),
    onTertiaryContainer = Color(0xFFFFD9A0),
    error = HermexColors.ErrorDark,
    onError = Color.White,
    errorContainer = Color(0xFF3A1210),
    onErrorContainer = Color(0xFFFFB3AD),
    background = HermexColors.BackgroundDark,
    onBackground = HermexColors.LabelDark,
    surface = HermexColors.BackgroundDark,
    onSurface = HermexColors.LabelDark,
    surfaceVariant = HermexColors.SecondaryBackgroundDark,
    onSurfaceVariant = HermexColors.SecondaryLabelDark,
    outline = HermexColors.SeparatorDark,
    outlineVariant = Color(0xFF2C2C2E),
    surfaceTint = HermexColors.LabelDark,
    surfaceContainerLowest = Color(0xFF000000),
    surfaceContainerLow = Color(0xFF141416),
    surfaceContainer = HermexColors.SecondaryBackgroundDark,
    surfaceContainerHigh = Color(0xFF242426),
    surfaceContainerHighest = Color(0xFF2C2C2E),
)

private val LightColorScheme = lightColorScheme(
    primary = HermexColors.AccentBlueLight,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE0EEFF),
    onPrimaryContainer = Color(0xFF00325C),
    secondary = HermexColors.SecondaryLabelLight,
    onSecondary = HermexColors.BackgroundLight,
    secondaryContainer = HermexColors.BubbleLight,
    onSecondaryContainer = HermexColors.LabelLight,
    tertiary = HermexColors.WarningLight,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFF3E0),
    onTertiaryContainer = Color(0xFF5C3A00),
    error = HermexColors.ErrorLight,
    onError = Color.White,
    errorContainer = Color(0xFFFFE9E7),
    onErrorContainer = Color(0xFF7F1D16),
    background = HermexColors.BackgroundLight,
    onBackground = HermexColors.LabelLight,
    surface = HermexColors.BackgroundLight,
    onSurface = HermexColors.LabelLight,
    surfaceVariant = HermexColors.SecondaryBackgroundLight,
    onSurfaceVariant = HermexColors.SecondaryLabelLight,
    outline = HermexColors.SeparatorLight,
    outlineVariant = Color(0xFFE5E5EA),
    surfaceTint = HermexColors.LabelLight,
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF7F7FA),
    surfaceContainer = HermexColors.SecondaryBackgroundLight,
    surfaceContainerHigh = Color(0xFFECECF1),
    surfaceContainerHighest = Color(0xFFE5E5EA),
)

/**
 * Shape scale mirroring the iOS chrome: accessory cards 10, cells 12,
 * settings cards 18, composer/sheets 22.
 */
private val HermexShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(18.dp),
    extraLarge = RoundedCornerShape(22.dp),
)

object HermexTheme {
    val colors: HermexExtendedColors
        @Composable get() = LocalHermexColors.current
}

@Composable
fun HermexTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val extendedColors = if (darkTheme) DarkExtendedColors else LightExtendedColors
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.surface.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    CompositionLocalProvider(LocalHermexColors provides extendedColors) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = HermexTypography,
            shapes = HermexShapes,
            content = content
        )
    }
}
