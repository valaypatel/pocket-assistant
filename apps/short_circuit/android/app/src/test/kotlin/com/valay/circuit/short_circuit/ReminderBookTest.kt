package com.valay.circuit.short_circuit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ReminderBookTest {
    private fun r(id: String, at: Long) = Reminder(id, "Title $id", "", at)

    @Test
    fun `only reminders whose time came and that have not rung are due`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100), r("b", 200), r("c", 300)))
        assertEquals(listOf("a", "b"), book.due(250).map { it.id })
        book.markFired("a")
        assertEquals(listOf("b"), book.due(250).map { it.id })
        assertEquals(listOf("c"), book.upcoming(250).map { it.id })
    }

    @Test
    fun `a later sync keeps what already rang`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100)))
        book.markFired("a")
        book.merge(listOf(r("a", 100).copy(title = "Renamed")))
        assertEquals(true, book.get("a")!!.fired)
        assertEquals("Renamed", book.get("a")!!.title)
    }

    @Test
    fun `a new time rings again`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100)))
        book.markFired("a")
        book.merge(listOf(r("a", 500)))
        assertFalse(book.get("a")!!.fired)
        assertEquals(500L, book.get("a")!!.at)
    }

    @Test
    fun `a task the app no longer sends is dropped`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100), r("b", 200)))
        book.merge(listOf(r("b", 200)))
        assertNull(book.get("a"))
    }

    @Test
    fun `a snooze survives a sync that still has the old time`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100)))
        book.markFired("a")
        book.snooze("a", 700)
        // the app has not heard about the snooze yet and sends the old time
        book.merge(listOf(r("a", 100)))
        assertEquals(700L, book.get("a")!!.at)
        assertFalse(book.get("a")!!.fired)
        // once it has heard, it sends the new time
        book.merge(listOf(r("a", 700)))
        assertEquals(700L, book.get("a")!!.at)
        assertFalse(book.get("a")!!.fired)
    }

    @Test
    fun `done takes the reminder off the list`() {
        val book = ReminderBook()
        book.merge(listOf(r("a", 100)))
        book.done("a")
        assertEquals(emptyList<Reminder>(), book.items)
    }
}
