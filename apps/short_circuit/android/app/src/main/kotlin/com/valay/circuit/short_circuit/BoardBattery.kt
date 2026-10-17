package com.valay.circuit.short_circuit

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat

/**
 * Tells the person once when Circuit's battery runs low. Circuit reports its charge as "bat=N" in the
 * status it sends over Bluetooth, so this works with the app in the background. One alert per dip: it
 * is armed again when the charge climbs back above [clearAt].
 */
object BoardBattery {
    const val lowAt = 15
    const val clearAt = 25
    private const val channelId = "board_battery"
    private const val notificationId = 4301
    private const val preferencesName = "circuit_board_battery"
    private const val warnedKey = "warned"

    /** "bat=N" from a status message, or null when the board did not send one (or has no battery reading). */
    fun percentIn(message: String): Int? =
        message.lines().firstNotNullOfOrNull { line ->
            if (line.startsWith("bat=")) line.removePrefix("bat=").trim().toIntOrNull() else null
        }?.takeIf { it in 0..100 }

    /** What to do for this charge given whether the person was already told: alert, re-arm, or nothing. */
    fun decide(percent: Int, warned: Boolean): Action = when {
        percent <= lowAt && !warned -> Action.Alert
        percent >= clearAt && warned -> Action.Rearm
        else -> Action.Nothing
    }

    enum class Action { Alert, Rearm, Nothing }

    fun onStatus(context: Context, message: String) {
        val percent = percentIn(message) ?: return
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        when (decide(percent, preferences.getBoolean(warnedKey, false))) {
            Action.Alert -> {
                preferences.edit().putBoolean(warnedKey, true).apply()
                show(context, percent)
            }
            Action.Rearm -> preferences.edit().putBoolean(warnedKey, false).apply()
            Action.Nothing -> {}
        }
    }

    private fun show(context: Context, percent: Int) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(channelId, "Circuit battery", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Tells you when Circuit's battery is low"
            },
        )
        val open = PendingIntent.getActivity(
            context,
            notificationId,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Circuit battery is low")
            .setContentText("About $percent% left. Plug Circuit in to charge it.")
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            manager.notify(notificationId, notification)
        } catch (_: SecurityException) {
            // no notification permission: nothing to show
        }
    }
}
