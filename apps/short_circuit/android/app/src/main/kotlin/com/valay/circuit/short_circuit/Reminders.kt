package com.valay.circuit.short_circuit

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reminders that ring as app notifications. The Flutter side owns the tasks and sends the
 * whole list through [sync]; this schedules the alarms, survives reboots, and reports what
 * the person did from the notification ("Done", "Snooze") back through [takeEvents].
 */
object Reminders {
    const val actionFire = "com.valay.circuit.short_circuit.REMINDER_FIRE"
    const val actionDone = "com.valay.circuit.short_circuit.REMINDER_DONE"
    const val actionSnooze = "com.valay.circuit.short_circuit.REMINDER_SNOOZE"
    const val extraId = "reminder_id"
    private const val channelId = "reminders"
    private const val prefs = "circuit_reminders"
    private const val snoozeMs = 10 * 60 * 1000L

    private val lock = Any()

    /** Called by the app with every open task that has a time. */
    fun sync(context: Context, incoming: List<Reminder>) = synchronized(lock) {
        val before = load(context).items
        val book = ReminderBook(before)
        book.merge(incoming)
        // anything that left the list must not ring
        before.filter { old -> book.get(old.id) == null }.forEach { cancel(context, it.id) }
        save(context, book)
        schedule(context, book)
    }

    /** After a reboot or an app update, which both clear alarms. */
    fun reschedule(context: Context) = synchronized(lock) {
        schedule(context, load(context))
    }

    /** The reminder's time came. */
    fun fire(context: Context, id: String) = synchronized(lock) {
        val book = load(context)
        val reminder = book.get(id) ?: return
        if (reminder.fired) return
        show(context, reminder)
        book.markFired(id)
        save(context, book)
    }

    fun done(context: Context, id: String) = synchronized(lock) {
        val book = load(context)
        val reminder = book.get(id) ?: return
        book.done(id)
        cancel(context, id)
        events(context, JSONObject().put("id", id).put("kind", "done").put("at", reminder.at))
        save(context, book)
    }

    fun snooze(context: Context, id: String) = synchronized(lock) {
        val book = load(context)
        if (book.get(id) == null) return
        val until = System.currentTimeMillis() + snoozeMs
        book.snooze(id, until)
        manager(context).cancel(id.hashCode())
        events(context, JSONObject().put("id", id).put("kind", "snooze").put("at", until))
        save(context, book)
        schedule(context, book)
    }

    /** What happened while the app was closed; each event is returned once. */
    fun takeEvents(context: Context): List<Map<String, Any>> = synchronized(lock) {
        val store = context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
        val list = JSONArray(store.getString("events", "[]"))
        store.edit().remove("events").apply()
        (0 until list.length()).map {
            val item = list.getJSONObject(it)
            mapOf("id" to item.getString("id"), "kind" to item.getString("kind"), "at" to item.getLong("at"))
        }
    }

    /** True when reminders can ring at the exact minute (otherwise Android may delay them a little). */
    fun exactAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms(context).canScheduleExactAlarms()

    private fun schedule(context: Context, book: ReminderBook) {
        val now = System.currentTimeMillis()
        // overdue ones ring now (the phone was off, or the app was updated)
        book.due(now).forEach { show(context, it); book.markFired(it.id) }
        save(context, book)
        book.upcoming(now).forEach { reminder ->
            val pending = firePending(context, reminder.id)
            val manager = alarms(context)
            if (exactAllowed(context)) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, pending)
            } else {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, pending)
            }
        }
    }

    private fun cancel(context: Context, id: String) {
        alarms(context).cancel(firePending(context, id))
        manager(context).cancel(id.hashCode())
    }

    private fun show(context: Context, reminder: Reminder) {
        val manager = manager(context)
        manager.createNotificationChannel(
            NotificationChannel(channelId, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Reminders you set on notes and tasks"
            },
        )
        val open = PendingIntent.getActivity(
            context,
            reminder.id.hashCode(),
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(reminder.title)
            .setContentText(reminder.detail.ifBlank { "Reminder from Circuit" })
            .setStyle(NotificationCompat.BigTextStyle().bigText(reminder.detail.ifBlank { "Reminder from Circuit" }))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setWhen(reminder.at)
            .setAutoCancel(true)
            .setContentIntent(open)
            .addAction(0, "Done", action(context, actionDone, reminder.id))
            .addAction(0, "Snooze 10 min", action(context, actionSnooze, reminder.id))
            .build()
        // without the notification permission this is silently dropped; the app asks for it
        // when the person sets their first reminder
        try {
            manager.notify(reminder.id.hashCode(), notification)
        } catch (_: SecurityException) {
        }
    }

    private fun firePending(context: Context, id: String) = action(context, actionFire, id)

    private fun action(context: Context, action: String, id: String): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction(action)
            .setData(android.net.Uri.parse("circuit-reminder://$id/$action"))
            .putExtra(extraId, id)
        return PendingIntent.getBroadcast(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun alarms(context: Context) = context.getSystemService(AlarmManager::class.java)
    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    private fun events(context: Context, event: JSONObject) {
        val store = context.getSharedPreferences(prefs, Context.MODE_PRIVATE)
        val list = JSONArray(store.getString("events", "[]"))
        list.put(event)
        store.edit().putString("events", list.toString()).apply()
    }

    private fun load(context: Context): ReminderBook {
        val text = context.getSharedPreferences(prefs, Context.MODE_PRIVATE).getString("items", "[]")
        val list = try { JSONArray(text) } catch (_: Exception) { JSONArray() }
        return ReminderBook(
            (0 until list.length()).mapNotNull {
                try {
                    val item = list.getJSONObject(it)
                    Reminder(
                        id = item.getString("id"),
                        title = item.getString("title"),
                        detail = item.optString("detail"),
                        at = item.getLong("at"),
                        fired = item.optBoolean("fired"),
                        snoozedFrom = if (item.has("snoozedFrom")) item.getLong("snoozedFrom") else null,
                    )
                } catch (_: Exception) {
                    null
                }
            },
        )
    }

    private fun save(context: Context, book: ReminderBook) {
        val list = JSONArray()
        book.items.forEach {
            list.put(
                JSONObject()
                    .put("id", it.id).put("title", it.title).put("detail", it.detail)
                    .put("at", it.at).put("fired", it.fired)
                    .apply { it.snoozedFrom?.let { from -> put("snoozedFrom", from) } },
            )
        }
        context.getSharedPreferences(prefs, Context.MODE_PRIVATE).edit().putString("items", list.toString()).apply()
    }

    /** Reads a list sent from the app. */
    fun parse(items: List<Map<String, Any?>>): List<Reminder> = items.mapNotNull {
        val id = it["id"] as? String ?: return@mapNotNull null
        val at = (it["at"] as? Number)?.toLong() ?: return@mapNotNull null
        Reminder(id, it["title"] as? String ?: "Reminder", it["detail"] as? String ?: "", at)
    }
}
