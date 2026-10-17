package com.valay.circuit.short_circuit

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.ByteArrayOutputStream

/**
 * Holds the phone's microphone while the person holds Push to talk: 16 kHz mono 16-bit speech, kept in
 * memory only, up to 30 seconds. Nothing is written to disk or saved as a note.
 */
object TalkRecorder {
    private const val sampleRate = 16000
    private const val maxBytes = sampleRate * 2 * 30
    private var record: AudioRecord? = null
    private var worker: Thread? = null
    private val speech = ByteArrayOutputStream()
    @Volatile private var running = false

    /** Null when listening has started, else why not. */
    @Synchronized
    fun start(): String? {
        if (running) return "Already listening"
        val size = maxOf(AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), 8192)
        val input = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size)
        } catch (_: Exception) {
            return "The microphone is not available"
        }
        if (input.state != AudioRecord.STATE_INITIALIZED) {
            input.release()
            return "The microphone is busy"
        }
        speech.reset()
        input.startRecording()
        running = true
        record = input
        worker = Thread {
            val chunk = ByteArray(4096)
            while (running && speech.size() < maxBytes) {
                val read = input.read(chunk, 0, chunk.size)
                if (read < 0) break
                if (read > 0) speech.write(chunk, 0, read)
            }
        }.also { it.start() }
        return null
    }

    /** Stops listening and returns everything heard (empty if it never started). */
    @Synchronized
    fun stop(): ByteArray {
        running = false
        worker?.join(1000)
        worker = null
        record?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        record = null
        return speech.toByteArray().also { speech.reset() }
    }
}
