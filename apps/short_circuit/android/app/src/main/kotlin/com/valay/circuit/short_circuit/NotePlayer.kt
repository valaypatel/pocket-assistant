package com.valay.circuit.short_circuit

import android.media.MediaDataSource
import android.media.MediaPlayer
import java.io.File

/**
 * Plays a note on the phone. It lives on its own, not inside the Circuit relay service, so
 * playback works with no Circuit, with the relay stopped, and right after an app update.
 * (It used to need the relay service to be running, which a phone-only user never has.)
 */
object NotePlayer {
    /** playing, completed (reached the end), stopped (cut short) or idle. */
    @Volatile var state: String = "idle"
        private set

    private var player: MediaPlayer? = null

    @Synchronized
    fun playFile(path: String): Boolean = try {
        val file = File(path)
        if (!file.exists()) {
            false
        } else {
            stop()
            start(MediaPlayer().apply { setDataSource(file.absolutePath) })
        }
    } catch (_: Exception) { false }

    /** Plays a WAV held in memory (an encrypted note the app has opened), so no plain file is written. */
    @Synchronized
    fun playBytes(wav: ByteArray): Boolean = try {
        stop()
        val source = object : MediaDataSource() {
            override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
                if (position >= wav.size) return -1
                val count = minOf(size, wav.size - position.toInt())
                System.arraycopy(wav, position.toInt(), buffer, offset, count)
                return count
            }
            override fun getSize(): Long = wav.size.toLong()
            override fun close() {}
        }
        start(MediaPlayer().apply { setDataSource(source) })
    } catch (_: Exception) { false }

    private fun start(next: MediaPlayer): Boolean {
        next.setOnCompletionListener {
            synchronized(this) {
                it.release()
                if (player === it) {
                    player = null
                    state = "completed"
                }
            }
        }
        return try {
            next.prepare()
            player = next
            next.start()
            state = "playing"
            true
        } catch (error: Exception) {
            try { next.release() } catch (_: Exception) {}
            player = null
            false
        }
    }

    @Synchronized
    fun pause(): Boolean = try {
        val current = player
        if (current != null && state == "playing") {
            current.pause()
            state = "paused"
            true
        } else false
    } catch (_: Exception) { false }

    @Synchronized
    fun resume(): Boolean = try {
        val current = player
        if (current != null && state == "paused") {
            current.start()
            state = "playing"
            true
        } else false
    } catch (_: Exception) { false }

    @Synchronized
    fun seekTo(milliseconds: Int) {
        try { player?.seekTo(milliseconds.coerceAtLeast(0)) } catch (_: Exception) { }
    }

    /** What the app's player bar shows: the state, where it is, and how long the note is. */
    @Synchronized
    fun status(): Map<String, Any> {
        val current = player
        val position = try { current?.currentPosition ?: 0 } catch (_: Exception) { 0 }
        val duration = try { current?.duration ?: 0 } catch (_: Exception) { 0 }
        return mapOf("state" to state, "positionMs" to position, "durationMs" to duration)
    }

    @Synchronized
    fun stop() {
        player?.let {
            try { it.stop() } catch (_: Exception) { }
            it.release()
            state = "stopped"
        }
        player = null
    }
}
