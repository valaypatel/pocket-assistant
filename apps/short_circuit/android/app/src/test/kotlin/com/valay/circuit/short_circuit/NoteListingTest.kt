package com.valay.circuit.short_circuit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NoteListingTest {
    @Test
    fun `a plain note has no group`() {
        val notes = NoteListing.parse("49,542720,1789000000\n")
        assertEquals(listOf(ListedNote(49, 542720, 1789000000, null)), notes)
    }

    @Test
    fun `parts carry their recording, position and whether they are the last`() {
        val notes = NoteListing.parse("10,1920060,1789000060,10,1,0\n11,1920060,1789000120,10,2,0\n12,300000,1789000130,10,3,1\n")
        assertEquals(listOf("10,1,0", "10,2,0", "10,3,1"), notes.map { it.group })
        assertEquals(listOf(10L, 11L, 12L), notes.map { it.id })
    }

    @Test
    fun `an unreadable line is skipped and a nonsense part description is ignored`() {
        val notes = NoteListing.parse("garbage\n7,100,1789000000,0,0,9\n8,x,1\n9,100,0\n")
        assertEquals(listOf(7L, 9L), notes.map { it.id })
        assertNull(notes[0].group)
        assertEquals(0L, notes[1].epoch)
    }
}
