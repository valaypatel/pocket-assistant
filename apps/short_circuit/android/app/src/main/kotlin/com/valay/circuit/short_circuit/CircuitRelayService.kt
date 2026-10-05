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
        private val serviceUuid = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
        private val commandUuid = UUID.fromString("0000fff1-0000-1000-8000-00805f9b34fb")
        private val relayUuid = UUID.fromString("0000fff2-0000-1000-8000-00805f9b34fb")
        private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        @Volatile var relayStatus: String = "Stopped"
        @Volatile private var activeService: CircuitRelayService? = null
        @Volatile var wifiNetworks: List<String> = emptyList()
        @Volatile var audioStatus: String? = null
        @Volatile var wifiStatus: String? = null
        @Volatile private var latestSyncedFile: String? = null
        @Volatile private var audioStatusListener: ((String) -> Unit)? = null
        fun writeToCircuit(value: String): Boolean = activeService?.writeCommand(value) ?: false
        fun playSyncedRecording(path: String): Boolean = activeService?.playRecording(path) ?: false
        fun playWavBytes(bytes: ByteArray): Boolean = activeService?.playBytes(bytes) ?: false
        fun stopPlayback() { activeService?.stopPlayback() }
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
    private var shouldReconnect = false
    private var circuitAddress: String? = null
    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null
    private var relayReady = false
    private val homeStatusRunnable = object : Runnable {
        override fun run() {
            if (relayReady) sendHomeStatus()
            reconnectHandler.postDelayed(this, 30_000)
        }
    }
    private var syncOutput: FileOutputStream? = null
    private var syncFile: File? = null
    private var syncExpectedBytes = 0L
    private var syncReceivedBytes = 0L
    private var syncCompleteStatus: String? = null
    private var mediaPlayer: android.media.MediaPlayer? = null
    private val reconnectRunnable = Runnable { circuitAddress?.let(::connect) }
    private val setupTimeout = Runnable {
        gatt?.let { failConnection(it, "Circuit setup timed out") }
    }
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            if (device.address != circuitAddress) return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)) {
                BluetoothDevice.BOND_BONDED -> {
                    reconnectDelayMs = 1000L
                    reconnectHandler.post { connect(device.address) }
                }
                BluetoothDevice.BOND_NONE -> stopForUnpairing()
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
        getSharedPreferences(preferencesName, MODE_PRIVATE).edit().putString(addressKey, circuitAddress).apply()
        reconnectHandler.removeCallbacks(reconnectRunnable)
        relayStatus = "Connecting to Circuit…"
        startAsForeground(relayStatus)
        connect(circuitAddress!!)
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        activeService = this
        registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }
    override fun onDestroy() {
        shouldReconnect = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        reconnectHandler.removeCallbacks(homeStatusRunnable)
        unregisterReceiver(bondReceiver)
        if (activeService === this) activeService = null
        relayStatus = "Stopped"
        gatt?.close()
        abandonAudioSync()
        syncGeneration++
        syncExecutor.shutdownNow()
        executor.shutdownNow()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null

    private fun connect(address: String) {
        if (!shouldReconnect || !hasBluetoothPermission()) return
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        gatt?.close()
        gatt = null
        command = null
        relayReady = false
        val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(address) ?: return
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            setRelayStatus("Pair Circuit in Short-Circuit to enable the relay")
            device.createBond()
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

    private fun stopForUnpairing() {
        shouldReconnect = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        reconnectHandler.removeCallbacks(setupTimeout)
        relayReady = false
        command = null
        gatt?.close()
        gatt = null
        getSharedPreferences(preferencesName, MODE_PRIVATE).edit().remove(addressKey).apply()
        relayStatus = "Circuit unpaired"
        stopSelf()
    }

    private fun failConnection(candidate: BluetoothGatt, reason: String) {
        if (this.gatt !== candidate) return
        reconnectHandler.removeCallbacks(setupTimeout)
        command = null
        relayReady = false
        this.gatt = null
        candidate.close()
        setRelayStatus(reason)
        scheduleReconnect()
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, state: Int) {
            if (state == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                if (this@CircuitRelayService.gatt !== gatt) {
                    gatt.close()
                    return
                }
                reconnectDelayMs = 1000L
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                setRelayStatus("Preparing secure Circuit relay…")
                if (!gatt.requestMtu(185) && !gatt.discoverServices()) {
                    failConnection(gatt, "Could not discover Circuit services")
                }
            } else {
                failConnection(gatt, "Circuit disconnected")
            }
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
                failConnection(gatt, "Circuit relay channel was not found")
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
            setRelayStatus("Circuit relay ready")
            writeCommand("@relay-test")
            // The display's clock and note counts must not depend on the app
            // screen being open, so the service sends them itself.
            reconnectHandler.removeCallbacks(homeStatusRunnable)
            reconnectHandler.postDelayed(homeStatusRunnable, 2500)
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleCharacteristic(characteristic.value ?: byteArrayOf())
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            handleCharacteristic(value)
        }
    }

    private fun handleCharacteristic(value: ByteArray) {
        if (value.size >= 2 && value[0] == 0xA5.toByte() && value[1] == 0x5A.toByte()) {
            syncOutput?.let { output ->
                val remaining = syncExpectedBytes - syncReceivedBytes
                val packetBytes = value.size - 2
                // Android can surface a duplicate final indication. Never
                // write beyond the WAV length announced by Circuit.
                val bytesToWrite = minOf(packetBytes, remaining.toInt())
                if (bytesToWrite <= 0) return
                output.write(value, 2, bytesToWrite)
                syncReceivedBytes += bytesToWrite
                // The final status notification can arrive behind the last
                // indication. The byte count is authoritative, so complete
                // locally as soon as the entire expected file is present.
                if (syncExpectedBytes > 0 && syncReceivedBytes == syncExpectedBytes) {
                    syncCompleteStatus = syncCompleteStatus ?: "Sync complete: ready on phone"
                }
                maybeFinishAudioSync()
            }
            return
        }
        handleRelayRequest(value.toString(Charsets.UTF_8))
    }

    private fun handleRelayRequest(request: String) {
        if (request.startsWith("@wifi-list")) {
            wifiNetworks = request.lines().drop(1).map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()
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
        if (request.startsWith("@audio-status\n")) {
            val status = request.substringAfter("@audio-status\n")
            when {
                status.startsWith("Sync started\n") -> beginAudioSync(status.substringAfter('\n').substringBefore(' ').toLongOrNull() ?: 0)
                status.startsWith("Sync complete") -> {
                    syncCompleteStatus = status
                    maybeFinishAudioSync()
                    reconnectHandler.postDelayed({
                        if (syncCompleteStatus != null) {
                            if (syncReceivedBytes == syncExpectedBytes) {
                                maybeFinishAudioSync()
                            } else {
                                val received = syncReceivedBytes
                                val expected = syncExpectedBytes
                                abandonAudioSync()
                                publishAudioStatus("Sync failed: incomplete transfer ($received/$expected bytes)")
                            }
                        }
                    }, 1500)
                    return
                }
                status.startsWith("Sync failed") -> abandonAudioSync()
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
            setRelayStatus(if (online) "Circuit relay online" else "Phone internet unavailable")
        }
    }

    private fun writeCommand(value: String): Boolean {
        if (!relayReady) return false
        val characteristic = command ?: return false
        return characteristic.let {
            characteristic.value = value.toByteArray()
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            gatt?.writeCharacteristic(characteristic) ?: false
        }
    }

    private fun beginAudioSync(expectedBytes: Long) {
        abandonAudioSync()
        syncExpectedBytes = expectedBytes
        syncReceivedBytes = 0
        syncCompleteStatus = null
        syncFile = File(filesDir, "circuit-note-${System.currentTimeMillis()}.wav")
        syncOutput = FileOutputStream(syncFile)
    }

    private fun maybeFinishAudioSync() {
        val status = syncCompleteStatus ?: return
        if (syncReceivedBytes != syncExpectedBytes) return
        val output = syncOutput ?: return
        output.flush()
        output.close()
        syncOutput = null
        var file = syncFile
        if (file != null && syncExpectedBytes > 0 && syncReceivedBytes == syncExpectedBytes) {
            val named = File(file.parentFile, file.nameWithoutExtension + "." + noteExtension(file))
            if (named != file && file.renameTo(named)) file = named
            latestSyncedFile = file.absolutePath
            publishAudioStatus("$status|${file.absolutePath}")
        } else {
            file?.delete()
            publishAudioStatus("Sync failed: incomplete transfer")
        }
        syncCompleteStatus = null
    }

    private fun abandonAudioSync() {
        syncOutput?.close()
        syncOutput = null
        syncFile?.delete()
        syncFile = null
        syncExpectedBytes = 0
        syncReceivedBytes = 0
        syncCompleteStatus = null
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

    private fun wifiNetwork(): Network? {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return null
        return manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
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
        val network = wifiNetwork()
        Log.i("CircuitSync", "Wi-Fi network available: ${network != null}")
        if (network == null) {
            publishAudioStatus("Sync needs Wi-Fi: connect your phone to the same network as Circuit")
            return
        }
        val factory = pinnedSocketFactory(fingerprint)
        fun open(path: String, method: String = "GET", from: Long = 0): HttpsURLConnection =
            (network.openConnection(URL("https://$host:$port$path")) as HttpsURLConnection).apply {
                sslSocketFactory = factory
                hostnameVerifier = HostnameVerifier { _, _ -> true }  // identity is the pinned fingerprint
                requestMethod = method
                connectTimeout = 6000
                readTimeout = 10000
                setRequestProperty("X-Circuit-Token", token)
                if (from > 0) setRequestProperty("Range", "bytes=$from-")
                if (method == "POST") { doOutput = true; setFixedLengthStreamingMode(0) }
            }
        try {
            val listing = open("/notes").run {
                if (responseCode != 200) throw IOException("Circuit refused the sync (HTTP $responseCode)")
                inputStream.bufferedReader().use { it.readText() }
            }
            val notes = listing.lines().filter { it.isNotBlank() }.mapNotNull { line ->
                val f = line.split(',')
                if (f.size < 3) null else Triple(f[0].toLongOrNull() ?: return@mapNotNull null,
                    f[1].toLongOrNull() ?: return@mapNotNull null, f[2].toLongOrNull() ?: 0L)
            }
            if (notes.isEmpty()) {
                publishAudioStatus("Sync complete: no new notes")
                return
            }
            val totalBytes = notes.sumOf { it.second }
            var doneBytes = 0L
            var lastPercent = -1
            Log.i("CircuitSync", "Listing ok: ${notes.size} notes, $totalBytes bytes")
            publishAudioStatus("Sync started\n$totalBytes bytes")
            for ((id, bytes, epoch) in notes) {
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
                    var attempts = 0
                    while (partial.length() < bytes) {
                        if (++attempts > 4) throw IOException("Connection to Circuit kept dropping")
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
                                    }
                                }
                            }
                        } catch (error: IOException) {
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
                }
                doneBytes += bytes
                val ack = open("/ack/$id", "POST")
                if (ack.responseCode != 200) throw IOException("Could not confirm note $id")
                latestSyncedFile = target.absolutePath
                publishAudioStatus("Sync complete: ready on phone|${target.absolutePath}|$epoch")
            }
            publishAudioStatus("Sync complete: all notes saved")
        } catch (error: Exception) {
            Log.e("CircuitSync", "Wi-Fi sync failed", error)
            val reason = when (error) {
                is javax.net.ssl.SSLException -> "Circuit's certificate did not match this phone"
                is java.net.SocketTimeoutException, is java.net.ConnectException, is java.net.NoRouteToHostException ->
                    "Circuit is not reachable on this Wi-Fi. Check both are on the same network and that Short-Circuit has Local network access in Android settings"
                else -> "${error.javaClass.simpleName}: ${error.message ?: "no details"}"
            }
            publishAudioStatus("Sync failed: $reason (${error.javaClass.simpleName})")
        }
    }

    private fun clearAudioFiles(): Boolean {
        latestSyncedFile = null
        filesDir.listFiles()
            ?.filter { isNoteFile(it) }
            ?.forEach { it.delete() }
        return writeCommand("@audio-clear")
    }

    private fun playRecording(path: String): Boolean = try {
        val file = File(path)
        if (!file.exists()) return false
        stopPlayback()
        mediaPlayer = android.media.MediaPlayer().apply {
            setDataSource(file.absolutePath)
            setOnCompletionListener {
                release()
                if (mediaPlayer === this) mediaPlayer = null
            }
            prepare()
            start()
        }
        true
    } catch (_: Exception) { false }

    /** Plays a WAV held in memory (an encrypted note the app has opened), so no plain file is written. */
    private fun playBytes(wav: ByteArray): Boolean = try {
        stopPlayback()
        val source = object : android.media.MediaDataSource() {
            override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
                if (position >= wav.size) return -1
                val count = minOf(size, wav.size - position.toInt())
                System.arraycopy(wav, position.toInt(), buffer, offset, count)
                return count
            }
            override fun getSize(): Long = wav.size.toLong()
            override fun close() {}
        }
        mediaPlayer = android.media.MediaPlayer().apply {
            setDataSource(source)
            setOnCompletionListener {
                release()
                if (mediaPlayer === this) mediaPlayer = null
            }
            prepare()
            start()
        }
        true
    } catch (_: Exception) { false }

    private fun stopPlayback() {
        mediaPlayer?.let {
            try { it.stop() } catch (_: Exception) { }
            it.release()
        }
        mediaPlayer = null
    }

    private fun hasBluetoothPermission() = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
        ActivityCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    private fun startAsForeground(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(channelId, "Circuit relay", NotificationManager.IMPORTANCE_LOW))
        val notification = notification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(notificationId, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(notificationId, notification)
    }
    private fun setRelayStatus(text: String) { relayStatus = text; updateNotification(text) }
    private fun updateNotification(text: String) { getSystemService(NotificationManager::class.java).notify(notificationId, notification(text)) }
    private fun notification(text: String): Notification = NotificationCompat.Builder(this, channelId)
        .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth).setContentTitle("Short-Circuit relay").setContentText(text).setOngoing(true).build()
}
