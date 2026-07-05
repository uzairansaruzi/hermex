package com.hermexapp.android.platform

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.hermexapp.android.MainActivity
import com.hermexapp.android.R

/**
 * Home-screen widget: the HERMEX wordmark over a gold "New chat" pill. Tapping it
 * launches the app straight into a fresh chat (iOS widget parity — the quick-chat
 * shortcut). No list contents, so no RemoteViewsService is needed.
 */
class HermexWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_hermex)
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                putExtra(EXTRA_NEW_CHAT, true)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val pending = PendingIntent.getActivity(context, 0, intent, flags)
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            views.setOnClickPendingIntent(R.id.widget_new_chat, pending)
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        /** Set when the app is launched from the widget's "New chat" button. */
        const val EXTRA_NEW_CHAT = "com.hermexapp.android.extra.NEW_CHAT"
    }
}
