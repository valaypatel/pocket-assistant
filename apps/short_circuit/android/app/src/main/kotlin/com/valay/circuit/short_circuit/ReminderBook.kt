package com.valay.circuit.short_circuit

/** One reminder: [at] is when it should ring, in epoch milliseconds. */
data class Reminder(
    val id: String,
    val title: String,
    val detail: String,
    val at: Long,
    /** It has rung and is waiting for the person to act on it. */
    val fired: Boolean = false,
    /** Set while snoozed: the time the app knows, so a later sync does not undo the snooze. */
    val snoozedFrom: Long? = null,
)

/** Something that happened to a reminder while the app was closed. */
data class ReminderEvent(val id: String, val kind: String, val at: Long)

/**
 * The list of reminders and the rules for changing it. The app owns the tasks and sends
 * the whole list whenever it changes; this keeps what has rung and what was snoozed.
 * No Android classes here, so it is tested on its own.
 */
class ReminderBook(start: List<Reminder> = emptyList()) {
    var items: List<Reminder> = start
        private set

    /** Replaces the list with what the app sent, keeping what already rang or was snoozed. */
    fun merge(incoming: List<Reminder>) {
        items = incoming.map { new ->
            val old = items.firstOrNull { it.id == new.id }
            when {
                old == null -> new.copy(fired = false, snoozedFrom = null)
                // snoozed here, and the app has not heard yet: keep the later time
                old.snoozedFrom == new.at -> old
                old.at == new.at -> old.copy(title = new.title, detail = new.detail)
                else -> new.copy(fired = false, snoozedFrom = null)
            }
        }
    }

    /** Reminders whose time has come and that have not rung yet. */
    fun due(now: Long): List<Reminder> = items.filter { !it.fired && it.at <= now }

    /** Reminders that still have to ring, soonest first. */
    fun upcoming(now: Long): List<Reminder> =
        items.filter { !it.fired && it.at > now }.sortedBy { it.at }

    fun markFired(id: String) {
        items = items.map { if (it.id == id) it.copy(fired = true) else it }
    }

    fun get(id: String): Reminder? = items.firstOrNull { it.id == id }

    /** Done from the notification: it leaves the list. */
    fun done(id: String) {
        items = items.filter { it.id != id }
    }

    /** Snoozed from the notification: it rings again at [until]. */
    fun snooze(id: String, until: Long) {
        items = items.map {
            if (it.id == id) it.copy(at = until, fired = false, snoozedFrom = it.snoozedFrom ?: it.at)
            else it
        }
    }
}
