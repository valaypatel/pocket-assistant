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

    @Test
    fun `the parts of one recording count as one note`() {
        // One long recording in three parts, then two plain notes: three notes, not five files.
        val notes = NoteListing.parse(
            "10,100,1,10,1,0\n11,100,1,10,2,0\n12,100,1,10,3,1\n20,100,2\n21,100,3\n"
        )
        assertEquals(3, NoteListing.recordingCount(notes))
        assertEquals(listOf(1, 1, 1, 2, 3), notes.indices.map { NoteListing.recordingNumber(notes, it) })
    }

    @Test
    fun `one recording in three parts shows as a single note`() {
        val notes = NoteListing.parse("10,100,1,10,1,0\n11,100,1,10,2,0\n12,100,1,10,3,1\n")
        assertEquals(1, NoteListing.recordingCount(notes))
    }
}
