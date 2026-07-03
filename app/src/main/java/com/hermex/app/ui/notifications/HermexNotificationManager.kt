package com.hermex.app.ui.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.hermex.app.MainActivity
import com.hermex.app.R
import com.hermex.app.ui.navigation.HermesDeepLink
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HermexNotificationManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    init {
        ensureChannels()
    }

    fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            RESPONSE_CHANNEL_ID,
            "Hermex responses",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifications when a Hermes response finishes."
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun notifyResponseComplete(sessionId: String, title: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            if (!granted) return
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = android.net.Uri.parse(HermesDeepLink.sessionUrl(sessionId))
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            sessionId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, RESPONSE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_hermex)
            .setContentTitle(title?.takeIf { it.isNotBlank() } ?: "Hermes response complete")
            .setContentText("Tap to return to the conversation.")
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        NotificationManagerCompat.from(context).notify(sessionId.hashCode(), notification)
    }

    companion object {
        const val RESPONSE_CHANNEL_ID = "hermex_responses"
    }
}
