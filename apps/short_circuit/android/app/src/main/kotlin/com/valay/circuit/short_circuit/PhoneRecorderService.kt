package com.valay.circuit.short_circuit

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import java.io.File
import kotlin.math.abs

/**
 * Records a voice note on the phone itself, with no Circuit involved. Runs as a
 * microphone foreground service so it keeps going with the screen off, and seals the
 * audio into the encrypted note format as it arrives (see NoteSealer).
 *
 * The person's controls are Pause/Resume, Stop (keeps the note) and Discard. There is no
 * length limit: the audio is stored as one-minute parts (see PartedNoteWriter) so memory
 * stays small however long it runs. It stops by itself only when storage runs low or on
 * an error; what was recorded is kept and the reason is reported.
 */
class PhoneRecorderService : Service() {
    companion object {
        const val actionStart = "com.valay.circuit.short_circuit.PHONE_RECORD_START"
        const val actionPause = "com.valay.circuit.short_circuit.PHONE_RECORD_PAUSE"
        const val actionResume = "com.valay.circuit.short_circuit.PHONE_RECORD_RESUME"
        const val actionStop = "com.valay.circuit.short_circuit.PHONE_RECORD_STOP"
        const val actionDiscard = "com.valay.circuit.short_circuit.PHONE_RECORD_DISCARD"

        const val partSeconds = 60
        const val maxParts = 9999 // about 166 hours; note numbers are one per part
        private const val sampleRate = 16000
        private const val minFreeBytes = 30L * 1024 * 1024
        private const val channelId = "phone_recorder"
        private const val notificationId = 43
        private const val preferencesName = "circuit_phone_recorder"

        @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null

        /** The latest state, for a screen that opens while a recording is running. */
        @Volatile var snapshot: Map<String, Any?> = mapOf("state" to "idle")

        /** A recording that ended while the app was not listening, until the app saves it. */
        fun pending(context: Context): Map<String, Any?>? {
            val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            val parts = prefs.getString("parts", null)?.split('\n')?.filter { it.isNotEmpty() } ?: return null
            if (parts.isEmpty()) return null
            if (snapshot["state"] == "recording" || snapshot["state"] == "paused") return null
            return mapOf(
                "parts" to parts,
                "keyId" to prefs.getInt("keyId", 0),
                "startedAt" to prefs.getLong("startedAt", 0L),
                "durationMs" to prefs.getLong("durationMs", 0L),
                "reason" to (prefs.getString("reason", null) ?: "interrupted"),
            )
        }

        fun clearPending(context: Context) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).edit().clear().apply()
        }

        fun send(context: Context, action: String, configure: Intent.() -> Unit = {}) {
            val intent = Intent(context, PhoneRecorderService::class.java).setAction(action).apply(configure)
            if (action == actionStart && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var thread: Thread? = null
    private var writer: PartedNoteWriter? = null
    private var directory: File? = null
    private var startedAt = 0L
    private var notifiedSecond = -1L
    private var notifiedPaused = false

    @Volatile private var running = false
    @Volatile private var pauseRequested = false
    @Volatile private var finishReason: String? = null // set by the controls to end the loop
    @Volatile private var discard = false
    @Volatile private var samples = 0L
    @Volatile private var level = 0f
    @Volatile private var paused = false

    private var audioFocus: AudioFocusRequest? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            // A call or another app took the microphone's audio path. Pause honestly instead
            // of quietly recording silence; the person resumes when they are ready.
            if (running && !paused) {
                pauseRequested = true
                interrupted = true
            }
        }
    }
    @Volatile private var interrupted = false

    private val ticker = object : Runnable {
        override fun run() {
            if (running) {
                publish(if (paused) "paused" else "recording")
                val second = samples / sampleRate
                if (second != notifiedSecond || paused != notifiedPaused) {
                    notifiedSecond = second
                    notifiedPaused = paused
                    updateNotification()
                }
                main.postDelayed(this, 250)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStart -> start(intent)
            actionPause -> pauseRequested = true
            actionResume -> { interrupted = false; pauseRequested = false }
            actionStop -> finishReason = "stopped"
            actionDiscard -> { discard = true; finishReason = "discarded" }
            else -> {}
        }
        // A button tapped after the recording already ended must not leave an idle service.
        if (!running && intent?.action != actionStart) stopSelf()
        return START_NOT_STICKY
    }

    private fun start(intent: Intent) {
        if (running) return
        // A service started with startForegroundService must show its notification, even
        // when it is about to give up, or Android ends the whole app.
        startForegroundNow()
        val path = intent.getStringExtra("path")
        val key = intent.getStringExtra("key")?.let { Base64.decode(it, Base64.NO_WRAP) }
        val keyId = intent.getIntExtra("keyId", 0)
        val noteId = intent.getIntExtra("noteId", 0)
        if (path == null || key == null || key.size != 32 || keyId == 0 || noteId == 0) {
            fail("setup")
            return
        }
        val target = File(path)
        val folder = target.parentFile ?: filesDir
        folder.mkdirs()
        if (folder.usableSpace < minFreeBytes) {
            fail("storage")
            return
        }
        val record = try {
            createRecord()
        } catch (error: Exception) {
            Log.w("PhoneRecorder", "Could not open the microphone: ${error.message}")
            fail("microphone")
            return
        }
        directory = folder
        startedAt = System.currentTimeMillis()
        val prefs = getSharedPreferences(preferencesName, MODE_PRIVATE)
        prefs.edit().clear().putInt("keyId", keyId).putLong("startedAt", startedAt).apply()
        // Remember every part as it opens, so a recording cut short can still be saved.
        writer = PartedNoteWriter(folder, key, keyId, noteId, sampleRate, partSeconds, onPartOpened = { part ->
            val known = prefs.getString("parts", "") ?: ""
            prefs.edit().putString("parts", if (known.isEmpty()) part.absolutePath else known + "\n" + part.absolutePath).commit()
        })
        samples = 0
        pauseRequested = false
        paused = false
        interrupted = false
        discard = false
        finishReason = null
        running = true
        requestFocus()
        main.post(ticker)
        thread = Thread({ capture(record) }, "phone-recorder").also { it.start() }
    }

    @SuppressLint("MissingPermission") // The app asks for the microphone before it calls start.
    private fun createRecord(): AudioRecord {
        val minimum = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw IllegalStateException("no buffer size")
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minimum, sampleRate * 2),
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("microphone not available")
        }
        return record
    }

    private fun capture(record: AudioRecord) {
        val buffer = ByteArray(sampleRate / 5 * 2) // 200 ms
        var reason = "stopped"
        var lastSpaceCheck = System.currentTimeMillis()
        try {
            record.startRecording()
            while (running && finishReason == null) {
                if (pauseRequested) {
                    if (!paused) {
                        record.stop() // the microphone indicator goes off while paused
                        paused = true
                    }
                    Thread.sleep(80)
                    continue
                }
                if (paused) {
                    record.startRecording()
                    paused = false
                }
                val read = record.read(buffer, 0, buffer.size)
                if (read < 0) {
                    reason = "error"
                    break
                }
                if (read > 0) {
                    writer?.append(buffer, read)
                    samples += read / 2
                    level = peak(buffer, read)
                }
                if ((writer?.partCount ?: 0) >= maxParts) {
                    reason = "limit"
                    break
                }
                val now = System.currentTimeMillis()
                if (now - lastSpaceCheck > 5000) {
                    lastSpaceCheck = now
                    if ((directory?.usableSpace ?: Long.MAX_VALUE) < minFreeBytes / 2) {
                        reason = "storage"
                        break
                    }
                }
            }
            if (finishReason != null) reason = finishReason!!
        } catch (error: Exception) {
            Log.w("PhoneRecorder", "Recording failed: ${error.message}")
            reason = "error"
        } finally {
            try { record.stop() } catch (_: Exception) {}
            record.release()
        }
        finish(reason)
    }

    private fun peak(buffer: ByteArray, length: Int): Float {
        var max = 0
        var i = 0
        while (i + 1 < length) {
            val sample = (buffer[i].toInt() and 0xff) or (buffer[i + 1].toInt() shl 8)
            max = maxOf(max, abs(sample.toShort().toInt()))
            i += 2
        }
        return (max / 32768f).coerceIn(0f, 1f)
    }

    private fun finish(reason: String) {
        running = false
        val durationMs = samples * 1000 / sampleRate
        var parts: List<String> = emptyList()
        try {
            if (discard) {
                writer?.abort()
                writer?.files?.forEach { it.delete() }
            } else {
                parts = writer?.finish()?.map { it.absolutePath } ?: emptyList()
            }
        } catch (error: Exception) {
            Log.w("PhoneRecorder", "Could not finish the note: ${error.message}")
            parts = writer?.files?.map { it.absolutePath } ?: emptyList()
        }
        writer = null
        abandonFocus()
        val prefs = getSharedPreferences(preferencesName, MODE_PRIVATE)
        if (discard || parts.isEmpty()) {
            prefs.edit().clear().apply()
        } else {
            prefs.edit().putLong("durationMs", durationMs).putString("reason", reason).apply()
        }
        main.post {
            main.removeCallbacks(ticker)
            val done = mapOf(
                "state" to if (discard) "discarded" else "stopped",
                "reason" to reason,
                "parts" to if (discard) emptyList<String>() else parts,
                "durationMs" to durationMs,
                "startedAt" to startedAt,
            )
            snapshot = mapOf("state" to "idle")
            listener?.invoke(done)
            // A new recording may already have started on this service; leave it running.
            if (!running) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun fail(reason: String) {
        main.post {
            snapshot = mapOf("state" to "idle")
            listener?.invoke(mapOf("state" to "failed", "reason" to reason))
            if (!running) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun publish(state: String) {
        val data = mapOf(
            "state" to state,
            "elapsedMs" to samples * 1000 / sampleRate,
            "level" to level.toDouble(),
            "parts" to (writer?.partCount ?: 0),
            "interrupted" to interrupted,
            "startedAt" to startedAt,
        )
        snapshot = data
        listener?.invoke(data)
    }

    private fun requestFocus() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(AudioManager::class.java)
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener(focusListener)
            .build()
        audioFocus = request
        manager.requestAudioFocus(request)
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        audioFocus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
        audioFocus = null
    }

    private fun startForegroundNow() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(channelId, "Voice recording", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = buildNotification(false, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(notificationId, notification)
        }
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(notificationId, buildNotification(paused, samples * 1000 / sampleRate))
    }

    private fun action(label: String, action: String, code: Int): Notification.Action {
        val intent = Intent(this, PhoneRecorderService::class.java).setAction(action)
        val pending = PendingIntent.getService(this, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val icon = Icon.createWithResource(this, R.drawable.ic_stat_circuit)
        return Notification.Action.Builder(icon, label, pending).build()
    }

    private fun buildNotification(isPaused: Boolean, elapsedMs: Long): Notification {
        val open = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val seconds = elapsedMs / 1000
        val clock = "%d:%02d".format(seconds / 60, seconds % 60)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, channelId) else Notification.Builder(this)
        return builder
            .setSmallIcon(R.drawable.ic_stat_circuit)
            .setContentTitle(if (isPaused) "Recording paused" else "Recording a voice note")
            .setContentText(clock)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(if (isPaused) action("Resume", actionResume, 1) else action("Pause", actionPause, 2))
            .addAction(action("Stop", actionStop, 3))
            .build()
    }

    override fun onDestroy() {
        // Killed from outside: keep what was sealed so far. The app finds it next time.
        if (running) {
            running = false
            try { writer?.finish() } catch (_: Exception) {}
            abandonFocus()
        }
        main.removeCallbacks(ticker)
        super.onDestroy()
    }
}
