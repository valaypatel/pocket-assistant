package com.valay.circuit.short_circuit

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PartedNoteWriterTest {
    private val key = ByteArray(32) { it.toByte() }

    /** Opens one note file the way the app does; fails if any chunk does not authenticate. */
    private fun open(file: File): Pair<Int, ByteArray> {
        val bytes = file.readBytes()
        val header = bytes.copyOfRange(0, 28)
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val noteId = buffer.getInt(12)
        val chunk = buffer.getInt(24)
        val out = java.io.ByteArrayOutputStream()
        var pos = 28
        var index = 0L
        while (pos < bytes.size) {
            val take = minOf(chunk + 16, bytes.size - pos)
            val nonce = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(noteId).putLong(index).array()
            val aad = ByteBuffer.allocate(36).order(ByteOrder.LITTLE_ENDIAN).put(header).putLong(index).array()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(aad)
            out.write(cipher.doFinal(bytes, pos, take))
            pos += take
            index++
        }
        return noteId to out.toByteArray()
    }

    private fun directory() = java.nio.file.Files.createTempDirectory("parts").toFile()

    @Test
    fun splitsAtTheBoundaryWithoutLosingOrRepeatingAudio() {
        val dir = directory()
        // 1 second parts at 100 samples/second: 200 bytes per part.
        val writer = PartedNoteWriter(dir, key, 7, 1000, sampleRate = 100, partSeconds = 1, chunkSize = 64)
        val audio = ByteArray(530) { (it * 7).toByte() } // 2.65 parts
        var at = 0
        var step = 37
        while (at < audio.size) {
            val take = minOf(step, audio.size - at)
            writer.append(audio.copyOfRange(at, at + take), take)
            at += take
            step += 11
        }
        val files = writer.finish()
        assertEquals(3, files.size)
        val opened = files.map { open(it) }
        assertEquals(listOf(1000, 1001, 1002), opened.map { it.first }) // never a repeated note number
        assertEquals(listOf(200, 200, 130), opened.map { it.second.size })
        assertArrayEquals(audio, opened.flatMap { it.second.toList() }.toByteArray())
    }

    @Test
    fun anExactMultipleLeavesNoEmptyLastPart() {
        val dir = directory()
        val writer = PartedNoteWriter(dir, key, 7, 5, sampleRate = 100, partSeconds = 1, chunkSize = 64)
        writer.append(ByteArray(400), 400)
        val files = writer.finish()
        assertEquals(2, files.size)
        assertTrue(files.all { it.length() > 28 })
    }

    @Test
    fun noAudioMakesNoFile() {
        val dir = directory()
        val writer = PartedNoteWriter(dir, key, 7, 5, sampleRate = 100, partSeconds = 1, chunkSize = 64)
        assertEquals(0, writer.finish().size)
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun reportsEachPartAsItOpens() {
        val dir = directory()
        val opened = mutableListOf<String>()
        val writer = PartedNoteWriter(dir, key, 7, 50, sampleRate = 100, partSeconds = 1, chunkSize = 64, onPartOpened = { opened.add(it.name) })
        writer.append(ByteArray(450), 450)
        writer.finish()
        assertEquals(listOf("phone-note-50.cnote", "phone-note-51.cnote", "phone-note-52.cnote"), opened)
    }
}
