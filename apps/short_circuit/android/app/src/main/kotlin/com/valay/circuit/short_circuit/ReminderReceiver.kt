package com.valay.circuit.short_circuit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Rings a reminder when its alarm goes off, and handles the notification's buttons. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(Reminders.extraId) ?: return
        when (intent.action) {
            Reminders.actionFire -> Reminders.fire(context, id)
            Reminders.actionDone -> Reminders.done(context, id)
            Reminders.actionSnooze -> Reminders.snooze(context, id)
        }
    }
}
