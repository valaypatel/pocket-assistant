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
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
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
        fun writeToCircuit(value: String): Boolean = activeService?.writeCommand(value) ?: false
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val reconnectHandler = Handler(Looper.getMainLooper())
    private var reconnectDelayMs = 1000L
    private var shouldReconnect = false
    private var circuitAddress: String? = null
    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null
    private var relayReady = false
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
        unregisterReceiver(bondReceiver)
        if (activeService === this) activeService = null
        relayStatus = "Stopped"
        gatt?.close()
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
                if (!gatt.discoverServices()) failConnection(gatt, "Could not discover Circuit services")
            } else {
                failConnection(gatt, "Circuit disconnected")
            }
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
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (!gatt.writeDescriptor(descriptor)) failConnection(gatt, "Could not subscribe to Circuit")
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != cccdUuid) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failConnection(gatt, "Circuit notification subscription failed")
                return
            }
            reconnectHandler.removeCallbacks(setupTimeout)
            relayReady = true
            setRelayStatus("Circuit relay ready")
            writeCommand("@relay-test")
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleRelayRequest(characteristic.value?.toString(Charsets.UTF_8).orEmpty())
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            handleRelayRequest(value.toString(Charsets.UTF_8))
        }
    }

    private fun handleRelayRequest(request: String) {
        if (request.startsWith("@wifi-list")) {
            wifiNetworks = request.lines().drop(1).map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()
            return
        }
        if (request.startsWith("@audio-status\n")) {
            audioStatus = request.substringAfter("@audio-status\n")
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
