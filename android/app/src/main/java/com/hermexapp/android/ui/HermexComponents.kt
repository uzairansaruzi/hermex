package com.hermexapp.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hermexapp.android.ui.theme.LocalHermexPalette

/** The circular gray icon buttons used across the iOS app's headers. */
@Composable
fun CircleButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    glyph: String? = null,
    size: Int = 44,
) {
    val palette = LocalHermexPalette.current
    Box(
        modifier = modifier
            .size(size.dp)
            .background(palette.card, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        when {
            icon != null -> Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface)
            glyph != null -> Text(glyph, fontSize = 18.sp, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

/** iOS-style screen header: circular back button, title (+ subtitle), circular actions. */
@Composable
fun HermexHeader(
    title: String,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    backIcon: ImageVector? = null,
    actions: @Composable () -> Unit = {},
) {
    val palette = LocalHermexPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (onBack != null) {
            CircleButton(onClick = onBack, icon = backIcon, glyph = if (backIcon == null) "‹" else null)
        }
        androidx.compose.foundation.layout.Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) { actions() }
    }
}

/** The HERMEX wordmark — approximates the iOS pixel-art logo with heavy gold type. */
@Composable
fun HermexWordmark(modifier: Modifier = Modifier) {
    Text(
        "HERMEX",
        modifier = modifier,
        color = LocalHermexPalette.current.accent,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Black,
        fontSize = 30.sp,
        letterSpacing = 2.sp,
    )
}

/** The rounded status badge from the iOS Tasks cards ("Paused", "ok", …). */
@Composable
fun StatusBadge(text: String, color: androidx.compose.ui.graphics.Color) {
    Surface(color = color.copy(alpha = 0.18f), shape = CircleShape) {
        Text(
            text,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp),
            color = color,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/** "7h ago"-style relative times, matching the iOS session rows. */
fun relativeTimeAgo(epochSeconds: Double?, nowMillis: Long = System.currentTimeMillis()): String {
    if (epochSeconds == null || epochSeconds <= 0) return ""
    val seconds = (nowMillis / 1000.0 - epochSeconds).toLong()
    return when {
        seconds < 60 -> "now"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        seconds < 86_400 * 30 -> "${seconds / 86_400}d ago"
        else -> "${seconds / (86_400 * 30)}mo ago"
    }
}
