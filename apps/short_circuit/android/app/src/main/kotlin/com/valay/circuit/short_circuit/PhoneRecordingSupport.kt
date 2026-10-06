package com.valay.circuit.short_circuit

import org.json.JSONArray
import org.json.JSONObject

/**
 * Note numbers for recordings started without the app running (from the home-screen widget).
 * The same rule as the app's PhoneRecordingIds: a recording starts at the larger of "last
 * used + 1" and the seconds since 1 January 2026, and a recording of N parts takes at least
 * 60 x N seconds, so numbers never overlap even if the saved counter is lost.
 */
object PhoneNumbering {
    private const val epoch2026Seconds = 1_767_225_600L // 2026-01-01T00:00:00Z

    fun next(lastUsed: Long, nowEpochSeconds: Long): Int =
        maxOf(lastUsed + 1, nowEpochSeconds - epoch2026Seconds).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
}

/** A finished recording waiting for the app to turn it into a note. */
data class PendingRecording(
    val parts: List<String>,
    val keyId: Int,
    val startedAt: Long,
    val durationMs: Long,
    val reason: String,
)

/**
 * Finished recordings that the app has not saved as notes yet. A recording started from the
 * widget ends with the app closed, and several can end before it is next opened, so they wait
 * in a list (never a single slot that the next one would overwrite).
 */
object PendingQueue {
    fun parse(text: String?): List<PendingRecording> {
        if (text.isNullOrBlank()) return emptyList()
        return try {
            val array = JSONArray(text)
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val parts = item.optJSONArray("parts") ?: return@mapNotNull null
                val paths = (0 until parts.length()).map { parts.getString(it) }.filter { it.isNotEmpty() }
                if (paths.isEmpty()) return@mapNotNull null
                PendingRecording(
                    parts = paths,
                    keyId = item.optInt("keyId", 0),
                    startedAt = item.optLong("startedAt", 0L),
                    durationMs = item.optLong("durationMs", 0L),
                    reason = item.optString("reason", "stopped"),
                )
            }
        } catch (_: Exception) {
            emptyList() // a damaged list must never stop the app from starting
        }
    }

    fun serialize(list: List<PendingRecording>): String = JSONArray().apply {
        list.forEach { entry ->
            put(
                JSONObject()
                    .put("parts", JSONArray(entry.parts))
                    .put("keyId", entry.keyId)
                    .put("startedAt", entry.startedAt)
                    .put("durationMs", entry.durationMs)
                    .put("reason", entry.reason),
            )
        }
    }.toString()

    /** Adds a recording, replacing an earlier entry for the same first file. */
    fun add(list: List<PendingRecording>, entry: PendingRecording): List<PendingRecording> =
        list.filter { it.parts.first() != entry.parts.first() } + entry

    /** Removes the recording whose first file is [firstPath]; null removes all of them. */
    fun remove(list: List<PendingRecording>, firstPath: String?): List<PendingRecording> =
        if (firstPath == null) emptyList() else list.filter { it.parts.first() != firstPath }
}
