package com.hermex.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.hermex.app.R
import com.hermex.app.ui.theme.HermexTheme

/**
 * Composited HERMEX wordmark matching the iOS 4-layer effect:
 *
 * 1. **hermes_fill_mask** — template-tinted with [tint] (default: HermesGold).
 * 2. **hermes_shading_overlay** — composited with Multiply blend.
 * 3. **hermes_highlight** — composited with Screen blend.
 * 4. **hermes_outline_shadow** — drawn on top (SrcOver, default).
 *
 * The entire stack is rendered inside an offscreen compositing layer so that
 * Multiply/Screen blend against the wordmark layers, not the app background.
 *
 * Aspect ratio 643:185, default width 160dp (matches iOS SessionListView).
 */
@Composable
fun HermexWordmark(
    modifier: Modifier = Modifier,
    tint: Color = HermexTheme.colors.themeGold,
) {
    val fillMask = ImageBitmap.imageResource(R.drawable.hermes_fill_mask)
    val shadingOverlay = ImageBitmap.imageResource(R.drawable.hermes_shading_overlay)
    val highlight = ImageBitmap.imageResource(R.drawable.hermes_highlight)
    val outlineShadow = ImageBitmap.imageResource(R.drawable.hermes_outline_shadow)

    Canvas(
        modifier = modifier
            .width(160.dp)
            .aspectRatio(643f / 185f)
            .semantics { contentDescription = "HERMEX" }
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
    ) {
        val dstSize = IntSize(size.width.toInt(), size.height.toInt())
        val dstOffset = IntOffset.Zero

        // Layer 1: fill mask tinted with the brand color
        drawImage(
            image = fillMask,
            dstOffset = dstOffset,
            dstSize = dstSize,
            colorFilter = ColorFilter.tint(tint),
            filterQuality = FilterQuality.High,
        )

        // Layer 2: shading overlay — Multiply blend
        drawImage(
            image = shadingOverlay,
            dstOffset = dstOffset,
            dstSize = dstSize,
            blendMode = BlendMode.Multiply,
            filterQuality = FilterQuality.High,
        )

        // Layer 3: highlight — Screen blend
        drawImage(
            image = highlight,
            dstOffset = dstOffset,
            dstSize = dstSize,
            blendMode = BlendMode.Screen,
            filterQuality = FilterQuality.High,
        )

        // Layer 4: outline/shadow — normal (SrcOver)
        drawImage(
            image = outlineShadow,
            dstOffset = dstOffset,
            dstSize = dstSize,
            filterQuality = FilterQuality.High,
        )
    }
}
