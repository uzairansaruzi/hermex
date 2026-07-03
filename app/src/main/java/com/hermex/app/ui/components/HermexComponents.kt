package com.hermex.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hermex.app.ui.theme.HermexTheme

/**
 * Shared Hermex chrome, mirroring the iOS app's components: capsule status
 * pills with 12% tinted backgrounds, uppercase caption section headers,
 * translucent "settings card" surfaces, and monochrome capsule actions.
 */

/** Capsule badge like iOS `TranscriptStatusPill` / session state badges. */
@Composable
fun HermexStatusPill(
    text: String,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = tint,
        modifier = modifier
            .background(tint.copy(alpha = 0.12f), CircleShape)
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** Uppercase caption-semibold section header, as used across iOS Settings/Skills. */
@Composable
fun HermexSectionHeader(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        letterSpacing = 0.6.sp,
        modifier = modifier.padding(horizontal = 4.dp),
    )
}

/**
 * Card mirroring iOS `SettingsCard`: 18dp corners, translucent secondary
 * background fill, hairline stroke.
 */
@Composable
fun HermexCard(
    modifier: Modifier = Modifier,
    contentPadding: androidx.compose.foundation.layout.PaddingValues =
        androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 14.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)),
    ) {
        Column(modifier = Modifier.padding(contentPadding), content = content)
    }
}

/**
 * Translucent accessory surface used by chat timeline chrome (thinking and
 * tool-call cards) — iOS `chatTimelineAccessorySurface`.
 */
@Composable
fun HermexAccessorySurface(
    modifier: Modifier = Modifier,
    cornerRadius: androidx.compose.ui.unit.Dp = 10.dp,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    val border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))
    if (onClick != null) {
        Surface(
            onClick = onClick,
            modifier = modifier,
            shape = RoundedCornerShape(cornerRadius),
            color = color,
            border = border,
            content = content,
        )
    } else {
        Surface(
            modifier = modifier,
            shape = RoundedCornerShape(cornerRadius),
            color = color,
            border = border,
            content = content,
        )
    }
}

/** Circular gold initials avatar, mirroring the iOS home header avatar. */
@Composable
fun HermexAvatar(
    initials: String,
    modifier: Modifier = Modifier,
    size: androidx.compose.ui.unit.Dp = 36.dp,
) {
    val gold = HermexTheme.colors.themeGold
    Box(
        modifier = modifier
            .size(size)
            .background(gold, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = initials,
            style = MaterialTheme.typography.labelMedium,
            color = Color.Black,
        )
    }
}

/** Centered error state with retry, shared across screens. */
@Composable
fun HermexErrorState(
    message: String,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
        )
        FilledTonalButton(onClick = onRetry) {
            Text("Retry")
        }
    }
}

/** Centered empty state with an icon, mirroring iOS `ContentUnavailableView`. */
@Composable
fun HermexEmptyState(
    icon: ImageVector,
    title: String,
    description: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(44.dp),
        )
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (description != null) {
            Text(
                text = description,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/** Thin divider row spacer used between grouped rows (leading-inset like iOS). */
@Composable
fun HermexInsetDivider(startIndent: androidx.compose.ui.unit.Dp = 58.dp) {
    Row(Modifier.fillMaxWidth()) {
        androidx.compose.foundation.layout.Spacer(Modifier.size(width = startIndent, height = 0.dp))
        Box(
            Modifier
                .weight(1f)
                .height(1.dp)
                .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        )
    }
}
