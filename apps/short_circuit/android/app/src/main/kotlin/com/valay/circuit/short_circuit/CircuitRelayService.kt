package com.valay.circuit.short_circuit

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import org.json.JSONArray
import java.util.concurrent.Executors

class CircuitRelayService : Service() {
    companion object {
        const val extraAddress = "circuit_address"
        private const val channelId = "circuit_relay"
        private const val notificationId = 42
        private const val preferencesName = "circuit_relay"
        private const val addressKey = "circuit_address"
        private const val stoppedKey = "stopped_by_user"
        private val serviceUuid = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
        private val commandUuid = UUID.fromString("0000fff1-0000-1000-8000-00805f9b34fb")
        private val relayUuid = UUID.fromString("0000fff2-0000-1000-8000-00805f9b34fb")
        private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        @Volatile var relayStatus: String = "Stopped"
        /**
         * What the board last said about itself: "sync" (firmware 3: it works on its own and only has its radios on
         * for a sync, so its link ends by itself and is not worth chasing), "connected" (it stays linked), or null
         * (an older firmware, which stays linked).
         */
        @Volatile var boardMode: String? = null
        @Volatile private var activeService: CircuitRelayService? = null
        @Volatile var wifiNetworks: List<String> = emptyList()
        @Volatile var audioStatus: String? = null
        @Volatile var wifiStatus: String? = null
        @Volatile private var latestSyncedFile: String? = null
        @Volatile private var audioStatusListener: ((String) -> Unit)? = null
        /**
         * Brings the relay back after the system ended it (reboot, app update,
         * the process being killed). A relay the person switched off stays off.
         */
        fun resumeIfWanted(context: Context) {
            if (relayStatus != "Stopped") return
            val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            if (prefs.getString(addressKey, null) == null || prefs.getBoolean(stoppedKey, false)) return
            try {
                val intent = Intent(context, CircuitRelayService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: Exception) {
                // Android can refuse a background start; opening the app retries.
                Log.w("CircuitRelay", "Could not resume the relay: ${error.message}")
            }
        }

        /** Records the person's choice so a restart knows whether to resume. */
        fun rememberChoice(context: Context, stopped: Boolean) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit().putBoolean(stoppedKey, stopped).apply()
        }

        fun writeToCircuit(value: String): Boolean = activeService?.writeCommand(value) ?: false

        /** Sends a spoken message for Circuit to play. Null when Circuit took it, else why not. */
        fun speakToBoard(wav: ByteArray): String? {
            val service = activeService ?: return "Circuit is not connected"
            return service.upload("speak", wav)
        }

        /** Sends a firmware image for Circuit to install and restart into. Null when Circuit took it, else why not. */
        fun updateBoard(image: ByteArray): String? {
            val service = activeService ?: return "Circuit is not connected"
            return service.upload("firmware", image)
        }
        // Playback does not need the relay to be running; see NotePlayer.
        fun playSyncedRecording(path: String): Boolean = NotePlayer.playFile(path)
        fun playWavBytes(bytes: ByteArray): Boolean = NotePlayer.playBytes(bytes)
        fun stopPlayback() { NotePlayer.stop() }
        fun playLatestSyncedRecording(): Boolean = latestSyncedFile?.let(::playSyncedRecording) ?: false
        fun clearAudio(): Boolean = activeService?.clearAudioFiles() ?: false

        /** A downloaded note: ".wav" (older, plain) or ".cnote" (encrypted). */
        fun isNoteFile(file: File) =
            file.name.startsWith("circuit-note-") && (file.name.endsWith(".wav") || file.name.endsWith(".cnote"))

        /** Encrypted notes start with the format's magic, "CNT1". The extension follows the content. */
        fun noteExtension(file: File): String = try {
            file.inputStream().use { input ->
                val magic = ByteArray(4)
                if (input.read(magic) == 4 && String(magic, Charsets.ISO_8859_1) == "CNT1") "cnote" else "wav"
            }
        } catch (_: Exception) { "wav" }
        /** Synced note files as "path|epochSeconds", oldest first. */
        fun syncedNotes(context: Context): List<String> = context.filesDir.listFiles()
            ?.filter { isNoteFile(it) }
            ?.sortedBy { it.name }
            ?.map { "${it.absolutePath}|${it.name.removePrefix("circuit-note-").substringBefore('-').toLongOrNull() ?: 0}" }
            ?: emptyList()
        fun setAudioStatusListener(listener: ((String) -> Unit)?) {
            audioStatusListener = listener
        }
        private fun publishAudioStatus(status: String) {
            audioStatus = status
            audioStatusListener?.invoke(status)
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    // Sync runs on its own thread so a stalled download can never block the relay,
    // and a newer offer cancels an older attempt instead of queueing behind it.
    private val syncExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var syncGeneration = 0
    private val reconnectHandler = Handler(Looper.getMainLooper())
    private var reconnectDelayMs = 1000L
    private val connectedStatus = "Connected to Circuit"
    private var attemptStartedMs = 0L
    private var connectedAtMs = 0L
    private var shouldReconnect = false
    private var circuitAddress: String? = null
    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null
    private var relayReady = false
    // A link that died without Android saying so (the board was restarted or lost power, say) never calls
    // back, so nothing reconnected until the person tapped Reconnect. Every write to the board is expected to
    // be answered; one left unanswered for 20 s means the link is dead, so it is dropped and rebuilt.
    // Signal strength as the phone hears the board, sampled every 20 s while connected. It is written to the
    // log when weak, when it moves by 10 dB, or every 5 min, and always with a drop, so a drop can be put
    // next to how weak the link was just before it.
    @Volatile private var lastRssi: Int? = null
    @Volatile private var lastRssiAtMs = 0L
    private var lastRssiLogged: Int? = null
    private var lastRssiLoggedAtMs = 0L
    private var watchdogTicks = 0

    @Volatile private var lastWriteStartedMs = 0L
    @Volatile private var lastWriteDoneMs = 0L
    private val linkWatchdog = object : Runnable {
        override fun run() {
            val started = lastWriteStartedMs
            if (relayReady && started > 0 && lastWriteDoneMs < started &&
                SystemClock.elapsedRealtime() - started > 20_000
            ) {
                BtEventLog.add(this@CircuitRelayService, "watchdog: a write got no answer for 20 s, the link is dead")
                lastWriteStartedMs = 0L
                gatt?.let { failConnection(it, "Circuit stopped answering") }
            }
            if (relayReady && ++watchdogTicks % 2 == 0) {
                try { gatt?.readRemoteRssi() } catch (_: SecurityException) {}
            }
            reconnectHandler.postDelayed(this, 10_000)
        }
    }

    private val homeStatusRunnable = object : Runnable {
        override fun run() {
            if (relayReady) sendHomeStatus()
            // Circuit keeps its own clock and counts, and the app also sends this whenever a count changes, so
            // this is only a slow refresh.
            reconnectHandler.postDelayed(this, 300_000)
        }
    }
    private val reconnectRunnable = Runnable { circuitAddress?.let(::connect) }
    // Turning Bluetooth off kills the connection without a callback, and nothing then
    // brought it back when Bluetooth returned. Follow the adapter instead.
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val adapterState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            BtEventLog.add(this@CircuitRelayService, "phone Bluetooth " + when (adapterState) {
                BluetoothAdapter.STATE_OFF -> "off"
                BluetoothAdapter.STATE_ON -> "on"
                BluetoothAdapter.STATE_TURNING_OFF -> "turning off"
                BluetoothAdapter.STATE_TURNING_ON -> "turning on"
                else -> "state $adapterState"
            })
            when (adapterState) {
                BluetoothAdapter.STATE_OFF -> {
                    Log.i("CircuitRelay", "[BLE] Bluetooth turned off")
                    if (connectedAtMs > 0) {
                        // status -1: the phone's own Bluetooth went off, not a link failure.
                        Diagnostics.event(
                            this@CircuitRelayService, "relay_disconnect", 60_000L,
                            "status" to -1, "up_s" to (SystemClock.elapsedRealtime() - connectedAtMs) / 1000,
                        )
                        connectedAtMs = 0L
                    }
                    reconnectHandler.removeCallbacks(reconnectRunnable)
                    reconnectHandler.removeCallbacks(setupTimeout)
                    relayReady = false
                    command = null
                    gatt?.close()
                    gatt = null
                    setRelayStatus("Bluetooth is off")
                }
                BluetoothAdapter.STATE_ON -> {
                    Log.i("CircuitRelay", "[BLE] Bluetooth turned on")
                    if (shouldReconnect && circuitAddress != null) {
                        reconnectDelayMs = 1000L
                        reconnectHandler.removeCallbacks(reconnectRunnable)
                        reconnectHandler.postDelayed(reconnectRunnable, 2000L)
                    }
                }
            }
        }
    }
    private val setupTimeout = Runnable {
        gatt?.let { failConnection(it, "Circuit setup timed out") }
    }
    private fun bondName(state: Int) = when (state) {
        BluetoothDevice.BOND_NONE -> "none"
        BluetoothDevice.BOND_BONDING -> "bonding"
        BluetoothDevice.BOND_BONDED -> "bonded"
        else -> "?$state"
    }

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            if (device.address != circuitAddress) return
            val newState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            val oldState = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)
            // The first domino of a broken pairing: who changed the phone's bond, and when.
            BtEventLog.add(
                this@CircuitRelayService,
                "bond ${bondName(oldState)} -> ${bondName(newState)}" +
                    " reason=${intent.getIntExtra("android.bluetooth.device.extra.REASON", -1)}",
            )
            when (newState) {
                BluetoothDevice.BOND_BONDED -> {
                    reconnectDelayMs = 1000L
                    reconnectHandler.post { connect(device.address) }
                }
                BluetoothDevice.BOND_NONE -> pauseForRepair()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        circuitAddress = intent?.getStringExtra(extraAddress)
            ?: getSharedPreferences(preferencesName, MODE_PRIVATE).getString(addressKey, null)
        if (circuitAddress == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        shouldReconnect = true
        getSharedPreferences(preferencesName, MODE_PRIVATE).edit()
            .putString(addressKey, circuitAddress).putBoolean(stoppedKey, false).apply()
        reconnectHandler.removeCallbacks(reconnectRunnable)
        relayStatus = "Connecting to Circuit…"
        startAsForeground(relayStatus)
        connect(circuitAddress!!)
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        boardMode = null
        activeService = this
        registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
    }
    override fun onDestroy() {
        shouldReconnect = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        reconnectHandler.removeCallbacks(homeStatusRunnable)
        reconnectHandler.removeCallbacks(linkWatchdog)
        unregisterReceiver(bondReceiver)
        unregisterReceiver(adapterReceiver)
        if (activeService === this) activeService = null
        relayStatus = "Stopped"
        gatt?.close()
        syncGeneration++
        syncExecutor.shutdownNow()
        executor.shutdownNow()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null

    private fun connect(address: String) {
        if (!shouldReconnect || !hasBluetoothPermission()) return
        attemptStartedMs = SystemClock.elapsedRealtime()
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        gatt?.close()
        gatt = null
        command = null
        relayReady = false
        val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(address) ?: return
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            // Never start pairing from here: Android would pop up its pairing dialog
            // unprompted, as it did when the phone came back after being away.
            pauseForRepair()
            return
        }
        setRelayStatus("Connecting to Circuit…")
        gatt = device.connectGatt(this, false, callback, BluetoothDevice.TRANSPORT_LE)
        reconnectHandler.postDelayed(setupTimeout, 15_000L)
    }

    private fun scheduleReconnect() {
        if (!shouldReconnect || circuitAddress == null) return
        val delaySeconds = reconnectDelayMs / 1000
        setRelayStatus("Circuit reconnecting in ${delaySeconds}s…")
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.postDelayed(reconnectRunnable, reconnectDelayMs)
        reconnectDelayMs = (reconnectDelayMs * 2).coerceAtMost(30_000L)
    }

    /**
     * Android no longer holds the pairing (for instance after Circuit refused the phone's
     * saved key). Stop retrying, but keep the saved Circuit and everything stored, so the
     * app can offer "Repair pairing" and the user decides when to pair again.
     */
    private fun pauseForRepair() {
        Log.w("CircuitRelay", "[BLE] Circuit is not bonded; waiting for the user to repair pairing")
        BtEventLog.add(this, "relay paused: Circuit is not bonded, waiting for Repair pairing")
        shouldReconnect = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        relayReady = false
        command = null
        gatt?.close()
        gatt = null
        setRelayStatus("Circuit needs repair in Short-Circuit")
    }

    private fun failConnection(candidate: BluetoothGatt, reason: String) {
        BtEventLog.add(this, "relay failed: $reason")
        if (this.gatt !== candidate) return
        reconnectHandler.removeCallbacks(setupTimeout)
        command = null
        relayReady = false
        this.gatt = null
        candidate.close()
        setRelayStatus(reason)
        if (boardMode == "sync") {  // it ended sync mode (or left): it is asleep, and does not advertise until asked
            giveUpAsleep()
            return
        }
        scheduleReconnect()
    }

    /**
     * Circuit (firmware 3) only has its radios on while someone holds its key for a sync. The link ending means it
     * went back to sleep, so there is nothing to chase: stop quietly. Opening the app next time connects again.
     */
    private fun giveUpAsleep() {
        BtEventLog.add(this, "relay stopped: Circuit went back to sleep")
        shouldReconnect = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        getSharedPreferences(preferencesName, MODE_PRIVATE).edit().putBoolean(stoppedKey, true).apply()
        setRelayStatus("Circuit is asleep")
        stopSelf()
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, state: Int) {
            Log.i("CircuitRelay", "[BLE] connection state=$state status=$status")
            val seen = lastRssi
            val signal = if (seen == null) "no signal reading yet"
                else "last signal $seen dBm, ${(SystemClock.elapsedRealtime() - lastRssiAtMs) / 1000} s before"
            BtEventLog.add(this@CircuitRelayService, "gatt state=$state status=$status bond=${bondName(gatt.device.bondState)}" +
                if (state == BluetoothProfile.STATE_CONNECTED) "" else "; $signal")
            if (state == BluetoothProfile.STATE_CONNECTED) {
                lastRssi = null
                lastRssiLogged = null
            }
            if (state == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (this@CircuitRelayService.gatt !== gatt) {
                    gatt.close()
                    return
                }
                reconnectDelayMs = 1000L
                // A relaxed rhythm (an event every 100 to 125 ms): Circuit sends short commands and status here, and
                // files go over Wi-Fi. The high-priority mode (an event every 11 to 15 ms) kept its radio and
                // processor busy all day for nothing.
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER)
                setRelayStatus("Securing the connection…")
                if (!gatt.requestMtu(185) && !gatt.discoverServices()) {
                    failConnection(gatt, "Could not discover Circuit services")
                }
            } else {
                if (this@CircuitRelayService.gatt === gatt) {
                    val upSeconds = if (connectedAtMs > 0) (SystemClock.elapsedRealtime() - connectedAtMs) / 1000 else 0L
                    Diagnostics.event(
                        this@CircuitRelayService, "relay_disconnect", 60_000L,
                        "status" to status, "up_s" to upSeconds,
                    )
                    connectedAtMs = 0L
                }
                failConnection(gatt, "Circuit disconnected")
            }
        }
        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val now = SystemClock.elapsedRealtime()
            lastRssi = rssi
            lastRssiAtMs = now
            val before = lastRssiLogged
            if (rssi < -80 || before == null || Math.abs(rssi - before) >= 10 || now - lastRssiLoggedAtMs > 300_000) {
                BtEventLog.add(this@CircuitRelayService, "signal $rssi dBm" + if (rssi < -80) " (weak)" else "")
                lastRssiLogged = rssi
                lastRssiLoggedAtMs = now
            }
        }
        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            lastWriteDoneMs = SystemClock.elapsedRealtime()
            if (status != BluetoothGatt.GATT_SUCCESS) BtEventLog.add(this@CircuitRelayService, "write answered with status=$status")
        }
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (this@CircuitRelayService.gatt !== gatt) return
            if (!gatt.discoverServices()) failConnection(gatt, "Could not discover Circuit services")
        }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failConnection(gatt, "Circuit service discovery failed")
                return
            }
            val service = gatt.getService(serviceUuid) ?: run {
                failConnection(gatt, "Circuit service was not found")
                return
            }
            command = service.getCharacteristic(commandUuid) ?: run {
                failConnection(gatt, "Circuit command channel was not found")
                return
            }
            val relay = service.getCharacteristic(relayUuid) ?: run {
                failConnection(gatt, "Circuit's connection channel was not found")
                return
            }
            if (!gatt.setCharacteristicNotification(relay, true)) {
                failConnection(gatt, "Could not enable Circuit notifications")
                return
            }
            val descriptor = relay.getDescriptor(cccdUuid) ?: run {
                failConnection(gatt, "Circuit notification descriptor was not found")
                return
            }
            // Status uses notifications and the binary audio stream uses
            // confirmed indications, so retain both subscriptions.
            descriptor.value = byteArrayOf(0x03, 0x00)
            if (!gatt.writeDescriptor(descriptor)) failConnection(gatt, "Could not subscribe to Circuit")
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != cccdUuid) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failConnection(gatt, "Circuit notification subscription failed")
                return
            }
            if (descriptor.characteristic.uuid != relayUuid) return
            reconnectHandler.removeCallbacks(setupTimeout)
            relayReady = true
            setRelayStatus(connectedStatus)
            connectedAtMs = SystemClock.elapsedRealtime()
            Diagnostics.event(
                this@CircuitRelayService, "relay_ready", 60_000L,
                "setup_s" to (connectedAtMs - attemptStartedMs) / 1000,
            )
            // Ask for the board's health once the link has settled (after the home status).
            reconnectHandler.postDelayed({ if (relayReady) writeCommand("@wifi-status") }, 6000)
            writeCommand("@relay-test")
            // The display's clock and note counts must not depend on the app
            // screen being open, so the service sends them itself.
            reconnectHandler.removeCallbacks(homeStatusRunnable)
            reconnectHandler.postDelayed(homeStatusRunnable, 2500)
            lastWriteStartedMs = 0L
            lastWriteDoneMs = 0L
            reconnectHandler.removeCallbacks(linkWatchdog)
            reconnectHandler.postDelayed(linkWatchdog, 10_000)
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleCharacteristic(characteristic.value ?: byteArrayOf())
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            handleCharacteristic(value)
        }
    }

    private fun handleCharacteristic(value: ByteArray) {
        handleRelayRequest(value.toString(Charsets.UTF_8))
    }

    private fun handleRelayRequest(request: String) {
        if (request.startsWith("@wifi-list")) {
            wifiNetworks = request.lines().drop(1).map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()
            return
        }
        if (request.startsWith("@sync-status\n")) {
            request.lineSequence().firstOrNull { it.startsWith("mode=") }?.let { boardMode = it.substringAfter("mode=").trim() }
            Diagnostics.boardHealth(this, request)
            BoardBattery.onStatus(this, request)
            // Board health and playback snapshots belong to Dart as well as diagnostics.
            // Keep them separate from the last audio event, which is replayed on reopening.
            audioStatusListener?.invoke(request)
            return
        }
        if (request.startsWith("@wifi-status\n")) {
            // Delivered to Dart on the same channel as audio status, but cached
            // separately so it never overwrites the audio state.
            wifiStatus = request
            audioStatusListener?.invoke(request)
            return
        }
        if (request.startsWith("@sec-key\n") || request.startsWith("@sec-none")) {
            // The notes key travels only over the encrypted link. It goes straight to the app,
            // which keeps it in secure storage; it is not stored or logged here.
            audioStatusListener?.invoke(request)
            return
        }
        if (request.startsWith("@sync-offer\n")) {
            handleSyncOffer(request)
            return
        }
        if (request.startsWith("@speak-offer\n") || request.startsWith("@firmware-offer\n")) {
            speakOffer?.complete(request)
            return
        }
        if (request.startsWith("@audio-status\n")) {
            val status = request.substringAfter("@audio-status\n")
            if (status.startsWith("Broadcast failed") || status.startsWith("Broadcast needs") ||
                status.startsWith("Update failed") || status.startsWith("Update needs")
            ) {
                speakOffer?.completeExceptionally(IOException(status.substringAfter(": ", status)))
            }
            publishAudioStatus(status)
            return
        }
        if (request != "@relay\nCHECK") return
        executor.execute {
            val online = try {
                (URL("https://connectivitycheck.gstatic.com/generate_204").openConnection() as HttpURLConnection).run {
                    connectTimeout = 5000; readTimeout = 5000; requestMethod = "GET"; responseCode == 204
                }
            } catch (_: Exception) { false }
            writeCommand("@relay-result\n${if (online) "online" else "offline"}")
            setRelayStatus(if (online) connectedStatus else "Phone internet unavailable")
        }
    }

    private fun writeCommand(value: String): Boolean {
        if (!relayReady) return false
        val characteristic = command ?: return false
        return characteristic.let {
            characteristic.value = value.toByteArray()
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val started = gatt?.writeCharacteristic(characteristic) ?: false
            if (started && lastWriteDoneMs >= lastWriteStartedMs) lastWriteStartedMs = SystemClock.elapsedRealtime()
            started
        }
    }

    /** Time, date and note counts for the display, in the format the app screen also uses. */
    private fun sendHomeStatus() {
        val now = java.util.Calendar.getInstance()
        val time = "%02d:%02d".format(now.get(java.util.Calendar.HOUR_OF_DAY), now.get(java.util.Calendar.MINUTE))
        val date = java.text.SimpleDateFormat("EEE dd MMM", Locale.ENGLISH).format(now.time).uppercase(Locale.ENGLISH)
        // The app keeps its notes list encrypted, so the pending count comes from a number it
        // writes beside it; notes already downloaded are counted from the files themselves.
        val pending = try {
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getLong("flutter.circuit_pending_count", 0L).toInt()
        } catch (_: Exception) { 0 }
        val synced = filesDir.listFiles()?.count { isNoteFile(it) } ?: 0
        val offsetMinutes = TimeZone.getDefault().getOffset(now.timeInMillis) / 60_000
        writeCommand("@home\n$time\n$date\n$pending · $synced\n${now.timeInMillis / 1000}\n$offsetMinutes")
    }

    // ---- Wi-Fi sync ------------------------------------------------------
    // Circuit offers a session over the bonded BLE link: address, port, a
    // one-time token and its certificate fingerprint. We only ever talk to the
    // certificate with that fingerprint, and only over the phone's Wi-Fi.

    private fun handleSyncOffer(request: String) {
        val parts = request.lines()
        Log.i("CircuitSync", "Offer received: host=${parts.getOrNull(1)} port=${parts.getOrNull(2)} notes=${parts.getOrNull(5)}")
        val port = parts.getOrNull(2)?.toIntOrNull() ?: return
        val host = parts.getOrNull(1) ?: return
        val token = parts.getOrNull(3) ?: return
        val fingerprint = parts.getOrNull(4) ?: return
        val generation = ++syncGeneration
        syncExecutor.execute { runWifiSync(host, port, token, fingerprint, generation) }
    }

    @Volatile private var speakOffer: java.util.concurrent.CompletableFuture<String>? = null

    /**
     * Asks Circuit for a one-upload session over Bluetooth ([kind]: "speak" for a spoken message, "firmware"
     * for an update), then uploads [bytes] over Wi-Fi to the pinned certificate. Runs on a worker thread.
     * Null means Circuit accepted it.
     */
    private fun upload(kind: String, bytes: ByteArray): String? {
        val offer = java.util.concurrent.CompletableFuture<String>()
        speakOffer = offer
        try {
            if (!writeCommand("@$kind-prepare")) return "Circuit is not connected"
            val request = try {
                offer.get(12, java.util.concurrent.TimeUnit.SECONDS)
            } catch (error: java.util.concurrent.ExecutionException) {
                return error.cause?.message ?: "Circuit refused"
            } catch (_: java.util.concurrent.TimeoutException) {
                return "Circuit did not answer"
            }
            val parts = request.lines()
            val host = parts.getOrNull(1) ?: return "Circuit sent an incomplete offer"
            val port = parts.getOrNull(2)?.toIntOrNull() ?: return "Circuit sent an incomplete offer"
            val token = parts.getOrNull(3) ?: return "Circuit sent an incomplete offer"
            val fingerprint = parts.getOrNull(4) ?: return "Circuit sent an incomplete offer"
            val network = waitForWifi(4000) ?: return "Connect your phone to the same Wi-Fi as Circuit"
            val connection = (network.openConnection(URL("https://$host:$port/$kind")) as HttpsURLConnection).apply {
                sslSocketFactory = pinnedSocketFactory(fingerprint)
                hostnameVerifier = HostnameVerifier { _, _ -> true }  // identity is the pinned fingerprint
                requestMethod = "PUT"
                doOutput = true
                setFixedLengthStreamingMode(bytes.size)
                connectTimeout = 6000
                readTimeout = 30000  // the board saves a firmware image to its card before it answers
                setRequestProperty("X-Circuit-Token", token)
            }
            connection.outputStream.use { it.write(bytes) }
            val code = connection.responseCode
            connection.disconnect()
            return if (code == 200) null else "Circuit refused it (HTTP $code)"
        } catch (error: Exception) {
            Log.w("CircuitUpload", "Upload of $kind failed: ${error.message}")
            return "Could not reach Circuit over Wi-Fi"
        } finally {
            speakOffer = null
        }
    }

    private fun wifiNetwork(): Network? {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return null
        return manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    private fun waitForWifi(timeoutMs: Long): Network? {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            wifiNetwork()?.let { return it }
            if (SystemClock.elapsedRealtime() >= until) return null
            Thread.sleep(500)
        }
    }

    private fun pinnedSocketFactory(fingerprint: String): SSLSocketFactory {
        val trust = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                throw CertificateException("Client certificates are not used")
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val digest = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                val actual = digest.joinToString("") { "%02x".format(it) }
                if (!MessageDigest.isEqual(actual.toByteArray(), fingerprint.lowercase().toByteArray())) {
                    throw CertificateException("Certificate does not match the paired Circuit")
                }
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }.socketFactory
    }

    private fun runWifiSync(host: String, port: Int, token: String, fingerprint: String, generation: Int) {
        fun superseded() = generation != syncGeneration
        var network = wifiNetwork()
        Log.i("CircuitSync", "Wi-Fi network available: ${network != null}")
        if (network == null) {
            publishAudioStatus("Sync needs Wi-Fi: connect your phone to the same network as Circuit")
            return
        }
        val factory = pinnedSocketFactory(fingerprint)
        fun open(path: String, method: String = "GET", from: Long = 0): HttpsURLConnection =
            (network!!.openConnection(URL("https://$host:$port$path")) as HttpsURLConnection).apply {
                sslSocketFactory = factory
                hostnameVerifier = HostnameVerifier { _, _ -> true }  // identity is the pinned fingerprint
                requestMethod = method
                connectTimeout = 6000
                readTimeout = 10000
                setRequestProperty("X-Circuit-Token", token)
                if (from > 0) setRequestProperty("Range", "bytes=$from-")
                if (method == "POST") { doOutput = true; setFixedLengthStreamingMode(0) }
            }
        // A board from before Moments closes the connection on /moments (and counts a bad attempt), so
        // after the first failure the rest of this sync does not ask again.
        var momentsSupported = true
        try {
            val listing = open("/notes").run {
                if (responseCode != 200) throw IOException("Circuit refused the sync (HTTP $responseCode)")
                inputStream.bufferedReader().use { it.readText() }
            }
            val notes = NoteListing.parse(listing)
            if (notes.isEmpty()) {
                publishAudioStatus("Sync complete: no new notes")
                clearSyncNotification()
                return
            }
            val totalBytes = notes.sumOf { it.bytes }
            var doneBytes = 0L
            var lastPercent = -1
            var lastNotePercent = -1
            Log.i("CircuitSync", "Listing ok: ${notes.size} notes, $totalBytes bytes")
            publishAudioStatus("Sync started\n$totalBytes bytes")
            for ((noteIndex, entry) in notes.withIndex()) {
                val (id, bytes, epoch, group) = entry
                lastNotePercent = -1
                if (superseded()) return
                // The same recording may already be here under a different time stamp
                // (an acknowledgement was lost and Circuit offered it again). Reuse it
                // rather than keeping two copies.
                val existing = filesDir.listFiles()?.firstOrNull {
                    Regex("circuit-note-\\d+-$id\\.(wav|cnote)").matches(it.name) && it.length() == bytes
                }
                var target = existing ?: File(filesDir, "circuit-note-$epoch-$id.wav")
                val partial = File(filesDir, "circuit-note-$epoch-$id.part")
                if (!(target.exists() && target.length() == bytes)) {
                    val noteStartedMs = SystemClock.elapsedRealtime()
                    var interruptions = 0
                    var attempts = 0
                    var progressedTo = partial.length()
                    var lastProgressMs = SystemClock.elapsedRealtime()
                    while (partial.length() < bytes) {
                        // Circuit's memory is tight, so on a long download it can drop the connection
                        // now and then. Resuming picks up where it stopped, so only time without
                        // progress counts: Circuit keeps its Wi-Fi sync open for 25 seconds after the
                        // phone goes quiet, so keep trying for that long, with a pause between tries
                        // (a Wi-Fi network that has only just come back refuses at once).
                        if (partial.length() > progressedTo) {
                            progressedTo = partial.length()
                            lastProgressMs = SystemClock.elapsedRealtime()
                            attempts = 0
                        }
                        attempts++
                        if (attempts > 1) {
                            if (SystemClock.elapsedRealtime() - lastProgressMs > 24000) {
                                throw IOException("Connection to Circuit kept dropping")
                            }
                            Thread.sleep(1500)
                        }
                        // A phone that lost Wi-Fi comes back with a new network, and the old one can no
                        // longer be used (the socket cannot be bound to it). Wait briefly for Wi-Fi to
                        // return and carry on with the new one; give up at once if it does not.
                        network = waitForWifi(20000) ?: throw IOException("Wi-Fi connection lost")
                        try {
                            val have = partial.length()
                            val connection = open("/notes/$id", from = have)
                            if (connection.responseCode != 200 && connection.responseCode != 206) {
                                throw IOException("Circuit refused the download (HTTP ${connection.responseCode})")
                            }
                            // A 200 means the server ignored the range: start over.
                            val append = connection.responseCode == 206 && have > 0
                            if (!append) partial.delete()
                            FileOutputStream(partial, append).use { out ->
                                connection.inputStream.use { input ->
                                    val buffer = ByteArray(16 * 1024)
                                    while (true) {
                                        if (superseded()) return
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        out.write(buffer, 0, n)
                                        val percent = ((doneBytes + partial.length()) * 100 / totalBytes).toInt().coerceIn(0, 99)
                                        if (percent != lastPercent && percent % 2 == 0) {
                                            lastPercent = percent
                                            publishAudioStatus("Sync in progress: $percent%")
                                        }
                                        // This note's own progress, for its row in the app and the notification.
                                        val notePercent = (partial.length() * 100 / bytes).toInt().coerceIn(0, 99)
                                        if (notePercent != lastNotePercent && notePercent % 2 == 0) {
                                            lastNotePercent = notePercent
                                            publishAudioStatus("Sync note #$id: $notePercent% (${noteIndex + 1} of ${notes.size})")
                                            setSyncNotification(noteIndex + 1, notes.size, notePercent)
                                        }
                                    }
                                }
                            }
                        } catch (error: IOException) {
                            interruptions++
                            Log.w("CircuitSync", "Download attempt $attempts for note $id failed", error)
                            if (error is javax.net.ssl.SSLException && partial.length() == 0L) throw error
                        }
                    }
                    // Encrypted notes are kept as received; the name says which kind it is.
                    target = File(filesDir, "circuit-note-$epoch-$id.${noteExtension(partial)}")
                    if (partial.length() != bytes || !partial.renameTo(target)) {
                        partial.delete()
                        throw IOException("Note $id arrived incomplete")
                    }
                    val seconds = ((SystemClock.elapsedRealtime() - noteStartedMs) / 1000).coerceAtLeast(1)
                    Diagnostics.event(
                        this, "sync_stats", 0L,
                        "via" to "wifi",
                        "size_mb" to Diagnostics.megabytes(bytes),
                        "seconds" to seconds,
                        "interruptions" to interruptions,
                        "kb_s" to bytes / 1024 / seconds,
                    )
                }
                // One minute of a longer recording: remember which one and which part, so the app can
                // join the parts. Written before the app is told the file is here.
                if (group != null) File(filesDir, "${NoteListing.groupPrefix}$id.txt").writeText(group)
                // The Moments (bookmarks) of this part, if it has any: a small sealed file kept beside the
                // note. Best effort: its absence or a failed fetch never holds back the note itself.
                if (momentsSupported) {
                    try {
                        val moments = open("/moments/$id").run {
                            if (responseCode != 200) ByteArray(0) else inputStream.use { it.readBytes() }
                        }
                        val momentsFile = File(filesDir, "${NoteListing.momentsPrefix}$id.cmom")
                        if (moments.isNotEmpty() && moments.size <= 1024) {
                            momentsFile.writeBytes(moments)
                            Log.i("CircuitSync", "Saved ${moments.size} B of moments for note $id")
                        }
                    } catch (error: IOException) {
                        momentsSupported = false
                        Log.w("CircuitSync", "Moments not fetched for note $id", error)
                    }
                }
                doneBytes += bytes
                Log.i("CircuitSync", "Saved note $id as ${target.name} ($bytes B)")  // the extension says whether it is encrypted
                val ack = open("/ack/$id", "POST")
                if (ack.responseCode != 200) throw IOException("Could not confirm note $id")
                latestSyncedFile = target.absolutePath
                publishAudioStatus("Sync complete: ready on phone|${target.absolutePath}|$epoch")
            }
            publishAudioStatus("Sync complete: all notes saved")
            clearSyncNotification()
        } catch (error: Exception) {
            Log.e("CircuitSync", "Wi-Fi sync failed", error)
            Diagnostics.event(
                this, "sync_failed", 0L,
                "via" to "wifi",
                "cause" to when {
                    error is javax.net.ssl.SSLException -> "certificate"
                    error is java.net.SocketTimeoutException || error is java.net.ConnectException ||
                        error is java.net.NoRouteToHostException -> "unreachable"
                    error.message?.contains("Wi-Fi connection lost") == true -> "wifi_lost"
                    error.message?.contains("kept dropping") == true -> "dropping"
                    error.message?.contains("incomplete") == true -> "incomplete"
                    else -> "other"
                },
            )
            val reason = when (error) {
                is javax.net.ssl.SSLException -> "Circuit's certificate did not match this phone"
                is java.net.SocketTimeoutException, is java.net.ConnectException, is java.net.NoRouteToHostException ->
                    "Circuit is not reachable on this Wi-Fi. Check both are on the same network and that Short-Circuit has Local network access in Android settings"
                else -> when {
                    error.message?.contains("Wi-Fi connection lost") == true ->
                        "The phone lost its Wi-Fi connection. Reconnect to the same network as Circuit and sync again; what already arrived is kept"
                    error.message?.contains("kept dropping") == true ->
                        "The connection to Circuit kept dropping. Sync again; what already arrived is kept"
                    else -> "${error.javaClass.simpleName}: ${error.message ?: "no details"}"
                }
            }
            publishAudioStatus("Sync failed: $reason (${error.javaClass.simpleName})")
        } finally {
            // Whatever ended it (done, failed, replaced by a newer sync), the bar does not stay on.
            clearSyncNotification()
        }
    }

    private fun clearAudioFiles(): Boolean {
        latestSyncedFile = null
        filesDir.listFiles()
            ?.filter { isNoteFile(it) || it.name.startsWith(NoteListing.groupPrefix) || it.name.startsWith(NoteListing.momentsPrefix) }
            ?.forEach { it.delete() }
        return writeCommand("@audio-clear")
    }

    private fun hasBluetoothPermission() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
        ActivityCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun startAsForeground(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(channelId, "Connection", NotificationManager.IMPORTANCE_LOW))
        val notification = notification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(notificationId, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(notificationId, notification)
    }
    // The healthy status reads as plain "Active" in the notification; anything else (connecting,
    // reconnecting, Bluetooth off, needs repair) is shown as it is, since that is what someone
    // looking at the notification wants to know.
    private fun notificationText(status: String): String =
        if (status == connectedStatus) "Active" else status

    // While notes download, the notification carries a progress bar: "Syncing note 2 of 5" and how far through.
    @Volatile private var syncNote = 0
    @Volatile private var syncNotes = 0
    @Volatile private var syncNotePercent = -1
    private fun setSyncNotification(index: Int, total: Int, percent: Int) {
        syncNote = index
        syncNotes = total
        syncNotePercent = percent
        updateNotification(relayStatus)
    }
    private fun clearSyncNotification() {
        if (syncNotePercent < 0) return
        syncNotePercent = -1
        updateNotification(relayStatus)
    }

    private fun setRelayStatus(text: String) { relayStatus = text; updateNotification(text) }
    private fun updateNotification(text: String) { getSystemService(NotificationManager::class.java).notify(notificationId, notification(text)) }
    private fun notification(text: String): Notification {
        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_stat_circuit).setContentTitle("Short-Circuit").setOngoing(true)
        val percent = syncNotePercent
        return if (percent >= 0) {
            val which = if (syncNotes > 1) "Syncing note $syncNote of $syncNotes" else "Syncing a note"
            builder.setContentText("$which · $percent%").setProgress(100, percent, false).setOnlyAlertOnce(true).build()
        } else {
            builder.setContentText(notificationText(text)).build()
        }
    }
}
