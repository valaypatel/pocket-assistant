package com.valay.circuit.short_circuit

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        stopService(Intent(this, CircuitRelayService::class.java))
                        result.success(null)
                    }
                    "status" -> result.success(CircuitRelayService.relayStatus)
                    "write" -> {
                        val value = call.argument<String>("value")
                        result.success(value != null && CircuitRelayService.writeToCircuit(value))
                    }
                    "wifiNetworks" -> result.success(CircuitRelayService.wifiNetworks)
                    else -> result.notImplemented()
                }
            }
    }
}
