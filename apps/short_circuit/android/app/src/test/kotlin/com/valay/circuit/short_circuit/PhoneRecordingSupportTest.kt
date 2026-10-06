package com.valay.circuit.short_circuit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneRecordingSupportTest {
    @Test
    fun numberIsTheLargerOfNextAndTheClock() {
        val now = 1_767_225_600L + 24_000_000L
        assertEquals(24_000_000, PhoneNumbering.next(0, now))
        assertEquals(24_000_006, PhoneNumbering.next(24_000_005, now)) // the counter is ahead
        assertEquals(24_000_000, PhoneNumbering.next(10, now)) // the clock is ahead
    }

    @Test
    fun aClockSetBackNeverReusesANumber() {
        val last = 24_000_050L
        assertEquals(24_000_051, PhoneNumbering.next(last, 1_767_225_600L + 100))
    }

    @Test
    fun numbersMatchTheAppsRuleForTheSameClock() {
        // Dart: max(last + 1, seconds since 2026-01-01 UTC); 5 s into 2026 with nothing used.
        assertEquals(5, PhoneNumbering.next(0, 1_767_225_605L))
    }

    private fun entry(first: String, extra: List<String> = emptyList()) =
        PendingRecording(listOf(first) + extra, 77, 1000L, 61_000L, "stopped")

    @Test
    fun theQueueSurvivesSavingAndLoading() {
        val list = listOf(entry("/f/phone-note-1.cnote", listOf("/f/phone-note-2.cnote")), entry("/f/phone-note-9.cnote"))
        assertEquals(list, PendingQueue.parse(PendingQueue.serialize(list)))
    }

    @Test
    fun twoRecordingsBeforeTheAppOpensBothSurvive() {
        var list = emptyList<PendingRecording>()
        list = PendingQueue.add(list, entry("/f/phone-note-1.cnote"))
        list = PendingQueue.add(list, entry("/f/phone-note-50.cnote"))
        assertEquals(2, list.size)
        // The same recording reported twice stays one entry.
        list = PendingQueue.add(list, entry("/f/phone-note-50.cnote"))
        assertEquals(2, list.size)
    }

    @Test
    fun savingOneRemovesOnlyThatOne() {
        val list = listOf(entry("/f/phone-note-1.cnote"), entry("/f/phone-note-50.cnote"))
        assertEquals(listOf("/f/phone-note-50.cnote"), PendingQueue.remove(list, "/f/phone-note-1.cnote").map { it.parts.first() })
        assertTrue(PendingQueue.remove(list, null).isEmpty())
    }

    @Test
    fun aDamagedListIsEmptyNotAnError() {
        assertTrue(PendingQueue.parse("not json").isEmpty())
        assertTrue(PendingQueue.parse(null).isEmpty())
        assertTrue(PendingQueue.parse("[{\"parts\":[]},{\"x\":1}]").isEmpty())
    }
}
