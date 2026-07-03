package com.hermex.app.ui.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.hermex.app.data.model.ToolStreamEvent
import com.hermex.app.ui.components.HermexStatusPill
import com.hermex.app.ui.theme.HermexTheme
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

@Composable
fun ToolCallCardView(
    toolCall: ToolStreamEvent,
    isCompleted: Boolean,
    modifier: Modifier = Modifier
) {
    var isExpanded by remember { mutableStateOf(false) }
    val displayName = toolCall.toolName ?: toolCall.name ?: "Tool call"
    val isError = false // Server does not currently expose isError on ToolStreamEvent.
    val statusIcon = when {
        isError -> Icons.Default.Warning
        isCompleted -> Icons.Default.CheckCircle
        else -> null
    }
    val statusColor = when {
        isError -> MaterialTheme.colorScheme.error
        isCompleted -> HermexTheme.colors.success
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val arguments = toolCall.arguments?.let { formatJson(it) }
    val result = toolCall.result?.let { formatJson(it) }

    Surface(
        shape = RoundedCornerShape(9.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier
                .clickable { isExpanded = !isExpanded }
                .padding(horizontal = 10.dp, vertical = 8.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                statusIcon?.let {
                    Icon(
                        imageVector = it,
                        contentDescription = null,
                        tint = statusColor,
                        modifier = Modifier.size(16.dp)
                    )
                }
                Text(
                    text = displayName,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
                HermexStatusPill(
                    text = when {
                        isError -> "Error"
                        isCompleted -> "Done"
                        else -> "Running"
                    },
                    tint = statusColor
                )
                Icon(
                    imageVector = if (isExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (isExpanded) "Collapse" else "Expand",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            AnimatedVisibility(
                visible = isExpanded,
                enter = expandVertically(animationSpec = tween(200)),
                exit = shrinkVertically(animationSpec = tween(200))
            ) {
                Column(modifier = Modifier.padding(top = 8.dp)) {
                    if (!arguments.isNullOrBlank()) {
                        ToolCallSection(title = "Arguments", content = arguments)
                    }
                    if (!result.isNullOrBlank()) {
                        ToolCallSection(title = "Result", content = result)
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolCallSection(
    title: String,
    content: String
) {
    Column(modifier = Modifier.padding(bottom = 8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(bottom = 4.dp)
        )
        Surface(
            shape = RoundedCornerShape(9.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
        ) {
            Text(
                text = content,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier
                    .padding(8.dp)
                    .fillMaxWidth()
            )
        }
    }
}

private val jsonPrettyPrinter = Json {
    prettyPrint = true
    prettyPrintIndent = "  "
}

private fun formatJson(element: JsonElement): String {
    return try {
        jsonPrettyPrinter.encodeToString(JsonElement.serializer(), element)
    } catch (_: Exception) {
        element.toString()
    }
}
