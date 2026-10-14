package com.valay.circuit.short_circuit

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A short, private log of Bluetooth events on this phone (connects, drops, pairing changes), kept in the
 * app's own folder and trimmed to the newest lines. It exists to answer "why did pairing break?" after the
 * fact, without a computer attached: nothing in it leaves the phone unless the person reads it out.
 */
object BtEventLog {
    private const val NAME = "bluetooth-events.log"
    private const val MAX_BYTES = 96 * 1024
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    @Synchronized
    fun add(context: Context, line: String) {
        try {
            val file = File(context.filesDir, NAME)
            if (file.exists() && file.length() > MAX_BYTES) {
                // Keep the newest half.
                val lines = file.readLines()
                file.writeText(lines.drop(lines.size / 2).joinToString("\n", postfix = "\n"))
            }
            file.appendText("${stamp.format(Date())} $line\n")
        } catch (_: Exception) {
            // A log must never become a failure.
        }
    }

    @Synchronized
    fun read(context: Context, lines: Int): String = try {
        File(context.filesDir, NAME).takeIf { it.exists() }?.readLines()?.takeLast(lines)?.joinToString("\n") ?: ""
    } catch (_: Exception) {
        ""
    }
}
