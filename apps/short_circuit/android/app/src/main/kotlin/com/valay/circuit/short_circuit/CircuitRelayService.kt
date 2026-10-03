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
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
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
        private val serviceUuid = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
        private val commandUuid = UUID.fromString("0000fff1-0000-1000-8000-00805f9b34fb")
        private val relayUuid = UUID.fromString("0000fff2-0000-1000-8000-00805f9b34fb")
        private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        @Volatile var relayStatus: String = "Stopped"
        @Volatile private var activeService: CircuitRelayService? = null
        @Volatile var wifiNetworks: List<String> = emptyList()
        fun writeToCircuit(value: String): Boolean = activeService?.writeCommand(value) ?: false
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        relayStatus = "Connecting to Circuit…"
        startAsForeground(relayStatus)
        intent?.getStringExtra(extraAddress)?.let(::connect)
        return START_STICKY
    }

    override fun onCreate() { super.onCreate(); activeService = this }
    override fun onDestroy() { if (activeService === this) activeService = null; relayStatus = "Stopped"; gatt?.close(); executor.shutdownNow(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null

    private fun connect(address: String) {
        if (!hasBluetoothPermission()) return
        gatt?.close()
        val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(address) ?: return
        gatt = device.connectGatt(this, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, state: Int) {
            if (state == BluetoothProfile.STATE_CONNECTED) { setRelayStatus("Circuit relay connected"); gatt.discoverServices() }
            else setRelayStatus("Circuit relay reconnecting…")
        }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service = gatt.getService(serviceUuid) ?: return
            command = service.getCharacteristic(commandUuid)
            val relay = service.getCharacteristic(relayUuid) ?: return
            gatt.setCharacteristicNotification(relay, true)
            relay.getDescriptor(cccdUuid)?.let { descriptor ->
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(descriptor)
            }
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid == cccdUuid && status == BluetoothGatt.GATT_SUCCESS) writeCommand("@relay-test")
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
