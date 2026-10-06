package com.valay.circuit.short_circuit

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phone must write exactly the bytes the board and the reference implementation do. */
class NoteSealerTest {
    private fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun vectors(): JSONObject {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "docs/security/test-vectors.json").exists()) dir = dir.parentFile
        return JSONObject(File(dir!!, "docs/security/test-vectors.json").readText())
    }

    @Test
    fun matchesTheSharedTestVectors() {
        val vectors = vectors()
        val cases = vectors.getJSONArray("cases")
        assertTrue(cases.length() > 0)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val plain = hex(case.getString("plaintextHex"))
            val sealer = NoteSealer(
                hex(vectors.getString("masterKeyHex")),
                vectors.getLong("keyId").toInt(),
                vectors.getInt("noteId"),
                chunkSize = vectors.getInt("chunkSize"),
            )
            val file = File.createTempFile("note", ".cnote")
            val writer = EncryptedNoteWriter(file, sealer)
            // Feed it in uneven pieces, as a microphone would.
            var at = 0
            var step = 7
            while (at < plain.size) {
                val take = minOf(step, plain.size - at)
                writer.append(plain.copyOfRange(at, at + take), take)
                at += take
                step += 5
            }
            writer.finish()
            assertArrayEquals(case.getString("name"), hex(case.getString("fileHex")), file.readBytes())
            file.delete()
        }
    }
}
