package com.valay.circuit.short_circuit

import android.Manifest
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews

/**
 * A "Record note" button for the home screen. Tapping it records on the phone through the same
 * recorder as the app, with the same notification, Pause and Stop.
 *
 * Preferred: it starts the recording itself, without opening the app. Android decides whether
 * that is allowed; if the key was never handed over, the microphone permission is missing, or
 * Android refuses (see PhoneRecorderService.directStartBlocked), the button opens the app,
 * which starts recording as soon as it is on screen.
 */
class RecordWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        render(context, manager, appWidgetIds)
    }

    companion object {
        const val extraAction = "circuit_action"
        const val actionRecord = "record"

        /** Opens the app and asks it to start recording once it is showing. */
        fun openAppIntent(context: Context): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(extraAction, actionRecord)

        /** Redraws every widget on the home screen from the recorder's current state. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, RecordWidgetProvider::class.java))
            if (ids.isNotEmpty()) render(context, manager, ids)
        }

        /** Whether tapping may start the recording without the app. */
        private fun canRecordDirectly(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED &&
                PhoneKeyStore.load(context) != null &&
                !PhoneRecorderService.directStartBlocked(context)

        private fun service(context: Context, action: String, code: Int): PendingIntent {
            val intent = Intent(context, PhoneRecorderService::class.java).setAction(action)
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            return if (action == PhoneRecorderService.actionToggle && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(context, code, intent, flags)
            } else {
                PendingIntent.getService(context, code, intent, flags)
            }
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val snapshot = PhoneRecorderService.snapshot
            val active = PhoneRecorderService.active
            val paused = active && snapshot["state"] == "paused"
            val elapsed = if (active) (snapshot["elapsedMs"] as? Number)?.toLong() ?: 0L else 0L
            val views = RemoteViews(context.packageName, R.layout.record_widget)
            if (!active) {
                views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_idle)
                views.setImageViewResource(R.id.widget_icon, R.drawable.ic_widget_mic)
                views.setTextViewText(R.id.widget_label, context.getString(R.string.widget_record))
                views.setTextViewTextSize(R.id.widget_label, TypedValue.COMPLEX_UNIT_SP, 16f)
                views.setTextColor(R.id.widget_label, 0xFF15171B.toInt())
                views.setViewVisibility(R.id.widget_sub, View.VISIBLE)
                views.setViewVisibility(R.id.widget_timer, View.GONE)
                views.setViewVisibility(R.id.widget_pause, View.GONE)
                views.setContentDescription(R.id.widget_main, context.getString(R.string.widget_record_description))
                val tap = if (canRecordDirectly(context)) {
                    service(context, PhoneRecorderService.actionToggle, 11)
                } else {
                    PendingIntent.getActivity(
                        context, 12, openAppIntent(context),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    )
                }
                views.setOnClickPendingIntent(R.id.widget_main, tap)
            } else {
                views.setInt(R.id.widget_root, "setBackgroundResource", R.drawable.widget_bg_active)
                views.setImageViewResource(R.id.widget_icon, R.drawable.ic_widget_stop)
                views.setTextViewText(R.id.widget_label, context.getString(if (paused) R.string.widget_paused else R.string.widget_recording))
                views.setTextViewTextSize(R.id.widget_label, TypedValue.COMPLEX_UNIT_SP, 12f)
                views.setTextColor(R.id.widget_label, if (paused) 0xFFB9B4AD.toInt() else 0xFFF7A08E.toInt())
                views.setViewVisibility(R.id.widget_sub, View.GONE)
                views.setViewVisibility(R.id.widget_timer, View.VISIBLE)
                views.setChronometer(R.id.widget_timer, SystemClock.elapsedRealtime() - elapsed, null, !paused)
                views.setViewVisibility(R.id.widget_pause, View.VISIBLE)
                views.setImageViewResource(R.id.widget_pause, if (paused) R.drawable.ic_widget_play else R.drawable.ic_widget_pause)
                views.setContentDescription(R.id.widget_main, context.getString(R.string.widget_stop_description))
                views.setContentDescription(
                    R.id.widget_pause,
                    context.getString(if (paused) R.string.widget_resume_description else R.string.widget_pause_description),
                )
                views.setOnClickPendingIntent(R.id.widget_main, service(context, PhoneRecorderService.actionToggle, 11))
                views.setOnClickPendingIntent(
                    R.id.widget_pause,
                    service(context, if (paused) PhoneRecorderService.actionResume else PhoneRecorderService.actionPause, 13),
                )
            }
            manager.updateAppWidget(ids, views)
        }
    }
}
