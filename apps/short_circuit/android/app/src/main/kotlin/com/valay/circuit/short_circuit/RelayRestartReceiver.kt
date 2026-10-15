package com.valay.circuit.short_circuit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the relay, and puts reminders back, after a reboot or an app update, which both end it. */
class RelayRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                CircuitRelayService.resumeIfWanted(context)
                // alarms do not survive a reboot or an update
                Reminders.reschedule(context)
            }
        }
    }
}
