package com.valay.circuit.short_circuit

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var audioStatusEvents: EventChannel.EventSink? = null

    /** What the person asked for by opening the app from the widget ("record"), until the app reads it. */
    private var launchAction: String? = null

    /** Test mode (Settings > Testing): a command sent with `adb shell am start --es test_cmd ...` is run. */
    private var testChannel: MethodChannel? = null
    private var pendingTestCommand: Map<String, String>? = null

    private fun testModeOn() = getSharedPreferences("circuit_test", MODE_PRIVATE).getBoolean("on", false)

    private fun takeTestCommand(intent: Intent?, appJustStarted: Boolean = false) {
        val cmd = intent?.getStringExtra("test_cmd") ?: return
        val args = intent.getStringExtra("test_args") ?: ""
        intent.removeExtra("test_cmd")
        intent.removeExtra("test_args")
        if (!testModeOn()) {
            android.util.Log.i("CircuitTest", "ignored '$cmd': test mode is off")
            return
        }
        val command = mapOf("cmd" to cmd, "args" to args)
        val channel = testChannel
        // A command that starts the app is held until the page asks for it: it is not listening yet.
        if (channel != null && !appJustStarted) channel.invokeMethod("command", command) else pendingTestCommand = command
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        takeLaunchAction(intent)
        takeTestCommand(intent, appJustStarted = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeLaunchAction(intent)
        takeTestCommand(intent)
    }

    private fun takeLaunchAction(intent: Intent?) {
        intent?.getStringExtra(RecordWidgetProvider.extraAction)?.let {
            launchAction = it
            intent.removeExtra(RecordWidgetProvider.extraAction)
        }
    }

    override fun onStart() {
        super.onStart()
        CircuitRelayService.resumeIfWanted(this)
    }

    override fun onPause() {
        CircuitRelayService.stopPlayback()
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        testChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "circuit/test").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setMode" -> {
                        getSharedPreferences("circuit_test", MODE_PRIVATE).edit()
                            .putBoolean("on", call.arguments as? Boolean ?: false).apply()
                        result.success(null)
                    }
                    "mode" -> result.success(testModeOn())
                    "pending" -> {
                        result.success(pendingTestCommand)
                        pendingTestCommand = null
                    }
                    "log" -> {
                        android.util.Log.i("CircuitTest", call.arguments as? String ?: "")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "circuit/audio_status")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioStatusEvents = events
                    CircuitRelayService.setAudioStatusListener { status ->
                        runOnUiThread { audioStatusEvents?.success(status) }
                    }
                    CircuitRelayService.audioStatus?.let { events?.success(it) }
                    CircuitRelayService.wifiStatus?.let { events?.success(it) }
                }

                override fun onCancel(arguments: Any?) {
                    audioStatusEvents = null
                    CircuitRelayService.setAudioStatusListener(null)
                }
            })
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "circuit/phone_recorder_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    PhoneRecorderService.listener = { data -> runOnUiThread { events?.success(data) } }
                }

                override fun onCancel(arguments: Any?) {
                    PhoneRecorderService.listener = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "circuit/phone_recorder")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        PhoneRecorderService.send(this, PhoneRecorderService.actionStart) {
                            putExtra("path", call.argument<String>("path"))
                            putExtra("key", call.argument<String>("key"))
                            putExtra("keyId", call.argument<Int>("keyId") ?: 0)
                            putExtra("noteId", call.argument<Int>("noteId") ?: 0)
                        }
                        result.success(null)
                    }
                    "pause" -> { PhoneRecorderService.send(this, PhoneRecorderService.actionPause); result.success(null) }
                    "resume" -> { PhoneRecorderService.send(this, PhoneRecorderService.actionResume); result.success(null) }
                    "stop" -> { PhoneRecorderService.send(this, PhoneRecorderService.actionStop); result.success(null) }
                    "discard" -> { PhoneRecorderService.send(this, PhoneRecorderService.actionDiscard); result.success(null) }
                    "snapshot" -> result.success(PhoneRecorderService.snapshot)
                    "pending" -> result.success(PhoneRecorderService.pending(this))
                    "clearPending" -> {
                        PhoneRecorderService.clearPending(this, call.argument<String>("path"))
                        result.success(null)
                    }
                    "saveKey" -> {
                        val keyId = call.argument<Int>("keyId") ?: 0
                        val key = call.argument<String>("key")?.let { android.util.Base64.decode(it, android.util.Base64.NO_WRAP) }
                        if (keyId != 0 && key != null && key.size == 32) {
                            PhoneKeyStore.save(this, keyId, key)
                            // The widget may now start a recording on its own.
                            RecordWidgetProvider.refresh(this)
                        }
                        result.success(null)
                    }
                    "launchAction" -> {
                        result.success(launchAction)
                        launchAction = null
                    }
                    "directory" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "circuit/relay")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val address = call.argument<String>("address")
                        if (address == null) {
                            result.error("missing_address", "Circuit address is required", null)
                        } else {
                            val intent = Intent(this, CircuitRelayService::class.java)
                                .putExtra(CircuitRelayService.extraAddress, address)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        CircuitRelayService.rememberChoice(this, stopped = true)
                        stopService(Intent(this, CircuitRelayService::class.java))
                        result.success(null)
                    }
                    "status" -> result.success(CircuitRelayService.relayStatus)
                    "btLog" -> {
                        call.argument<String>("line")?.let { BtEventLog.add(this, "app: $it") }
                        result.success(null)
                    }
                    "btLogRead" -> result.success(BtEventLog.read(this, call.argument<Int>("lines") ?: 80))
                    "write" -> {
                        val value = call.argument<String>("value")
                        result.success(value != null && CircuitRelayService.writeToCircuit(value))
                    }
                    "wifiNetworks" -> result.success(CircuitRelayService.wifiNetworks)
                    "audioStatus" -> result.success(CircuitRelayService.audioStatus)
                    "wifiStatus" -> result.success(CircuitRelayService.wifiStatus)
                    "playLatestSyncedRecording" -> result.success(CircuitRelayService.playLatestSyncedRecording())
                    "playWavBytes" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        result.success(bytes != null && CircuitRelayService.playWavBytes(bytes))
                    }
                    "playSyncedRecording" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && CircuitRelayService.playSyncedRecording(path))
                    }
                    "playbackStatus" -> result.success(NotePlayer.status())
                    "pausePlayback" -> result.success(NotePlayer.pause())
                    "resumePlayback" -> result.success(NotePlayer.resume())
                    "seekPlayback" -> {
                        NotePlayer.seekTo(call.argument<Int>("positionMs") ?: 0)
                        result.success(null)
                    }
                    "stopPlayback" -> {
                        CircuitRelayService.stopPlayback()
                        result.success(null)
                    }
                    "clearAudio" -> result.success(CircuitRelayService.clearAudio())
                    "syncedNotes" -> result.success(CircuitRelayService.syncedNotes(this))
                    "requestLocalNetwork" -> {
                        // Android 17 blocks connections to devices on the home
                        // network (Circuit's Wi-Fi sync) until this is granted.
                        val permission = "android.permission.ACCESS_LOCAL_NETWORK"
                        val needed = Build.VERSION.SDK_INT >= 37 &&
                            checkSelfPermission(permission) != android.content.pm.PackageManager.PERMISSION_GRANTED
                        if (needed) requestPermissions(arrayOf(permission), 4217)
                        result.success(!needed)
                    }
                    "syncReminders" -> {
                        @Suppress("UNCHECKED_CAST")
                        val items = (call.argument<List<Map<String, Any?>>>("items") ?: emptyList())
                        Reminders.sync(this, Reminders.parse(items))
                        result.success(Reminders.exactAllowed(this))
                    }
                    "takeReminderEvents" -> result.success(Reminders.takeEvents(this))
                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    }
                    "openCalendarEvent" -> {
                        val title = call.argument<String>("title")
                        val description = call.argument<String>("description")
                        val startMillis = call.argument<Number>("startMillis")?.toLong()
                        val endMillis = call.argument<Number>("endMillis")?.toLong()
                        if (title == null || startMillis == null || endMillis == null) {
                            result.error("missing_event", "Reminder details are incomplete", null)
                        } else {
                            val intent = Intent(Intent.ACTION_INSERT).apply {
                                data = CalendarContract.Events.CONTENT_URI
                                putExtra(CalendarContract.Events.TITLE, title)
                                putExtra(CalendarContract.Events.DESCRIPTION, description ?: "")
                                putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, startMillis)
                                putExtra(CalendarContract.EXTRA_EVENT_END_TIME, endMillis)
                            }
                            startActivity(intent)
                            result.success(true)
                        }
                    }
                    "requestBatteryExemption" -> {
                        val powerManager = getSystemService(PowerManager::class.java)
                        val alreadyExempt = powerManager.isIgnoringBatteryOptimizations(packageName)
                        if (!alreadyExempt && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:$packageName")))
                        }
                        result.success(alreadyExempt)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
