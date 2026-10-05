package com.valay.circuit.short_circuit

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics

/**
 * Usage events from the relay service, which runs with or without the app screen open.
 *
 * Counts, codes and sizes only: never note content, titles, key ids, device addresses or
 * error text. Nothing is sent from a debug build, when the build has no google-services.json,
 * or when the person has switched "Share crash reports and usage" off in Settings (the app
 * stores that choice, and this reads it). The Dart side has the same rules in telemetry.dart.
 */
object Diagnostics {
    private val names = setOf("relay_ready", "relay_disconnect", "sync_stats", "sync_failed", "board_health")
    private val word = Regex("^[a-z0-9_]{1,24}$")
    private val lastSent = HashMap<String, Long>()

    private fun on(context: Context): Boolean {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) return false
        if (FirebaseApp.getApps(context).isEmpty()) return false
        return context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.share_diagnostics", true)
    }

    /** [minGapMs] stops a flapping connection from sending an event for every flap. */
    fun event(context: Context, name: String, minGapMs: Long = 0L, vararg params: Pair<String, Any>) {
        if (name !in names) return
        val now = System.currentTimeMillis()
        synchronized(lastSent) {
            if (minGapMs > 0 && now - (lastSent[name] ?: 0L) < minGapMs) return
            lastSent[name] = now
        }
        val bundle = Bundle()
        for ((key, value) in params) {
            when (value) {
                is Boolean -> bundle.putLong(key, if (value) 1L else 0L)
                is Int -> bundle.putLong(key, value.toLong())
                is Long -> bundle.putLong(key, value)
                is String -> if (word.matches(value)) bundle.putString(key, value)
            }
        }
        val sent = on(context)
        Log.i("Diagnostics", "$name ${params.joinToString(" ") { "${it.first}=${it.second}" }}" + if (sent) "" else " (not sent)")
        if (sent) FirebaseAnalytics.getInstance(context).logEvent(name, bundle)
    }

    fun megabytes(bytes: Long): Long = Math.round(bytes / (1024.0 * 1024.0))

    /** "@sync-status" from the board: "waiting=N", "reset=R", "uptime=S", "free_min=B", "stack_min=B", "stops=N". */
    fun boardHealth(context: Context, message: String) {
        val fields = message.lines().drop(1).mapNotNull {
            val parts = it.split('=', limit = 2)
            if (parts.size == 2) parts[0] to (parts[1].toLongOrNull() ?: return@mapNotNull null) else null
        }.toMap()
        // Older firmware sends only waiting, reset and uptime.
        val freeMin = fields["free_min"] ?: return
        val uptime = fields["uptime"] ?: 0L
        // The board reports on every request; one event per boot is enough (uptime goes
        // backwards when it restarts).
        val preferences = context.getSharedPreferences("circuit_diagnostics", Context.MODE_PRIVATE)
        val previous = preferences.getLong("last_board_uptime", -1L)
        preferences.edit().putLong("last_board_uptime", uptime).apply()
        if (previous in 0..uptime) return
        event(
            context, "board_health", 0L,
            "reset" to (fields["reset"] ?: -1L),
            "free_min_kb" to freeMin / 1024,
            "stack_min" to (fields["stack_min"] ?: 0L),
            "stops" to (fields["stops"] ?: 0L),
            "uptime_min" to uptime / 60,
        )
    }
}
