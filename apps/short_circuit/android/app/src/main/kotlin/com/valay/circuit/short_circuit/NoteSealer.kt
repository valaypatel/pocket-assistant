package com.valay.circuit.short_circuit

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Writes the encrypted note format (CNT1) one chunk at a time, the same bytes Circuit
 * writes. See docs/security/README.md and docs/security/test-vectors.json.
 *
 * A nonce is note id + chunk number, so one key must never see the same note id twice.
 * Phone recordings use their own key and ids (see PhoneRecorder in Dart) for that reason.
 */
class NoteSealer(
    key: ByteArray,
    val keyId: Int,
    val noteId: Int,
    private val sampleRate: Int = 16000,
    val chunkSize: Int = 4096,
) {
    private val secret = SecretKeySpec(key, "AES")
    private var index = 0L

    val header: ByteArray = ByteBuffer.allocate(headerBytes).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("CNT1".toByteArray(Charsets.ISO_8859_1))
        put(1)
        put(0)
        putShort(headerBytes.toShort())
        putInt(keyId)
        putInt(noteId)
        putInt(sampleRate)
        putShort(1) // channels
        putShort(16) // bits per sample
        putInt(chunkSize)
    }.array()

    /** Seals the next chunk: ciphertext followed by its 16-byte tag. */
    fun seal(plain: ByteArray, length: Int): ByteArray {
        val nonce = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(noteId).putLong(index).array()
        val aad = ByteBuffer.allocate(headerBytes + 8).order(ByteOrder.LITTLE_ENDIAN)
            .put(header).putLong(index).array()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        index++
        return cipher.doFinal(plain, 0, length)
    }

    companion object {
        const val headerBytes = 28
    }
}

/**
 * An encrypted note being recorded. Audio is sealed as it arrives, so the file on disk is
 * always a valid note up to its last whole chunk: a crash or power loss keeps everything
 * before it, and no plain audio is ever written.
 */
class EncryptedNoteWriter(file: File, private val sealer: NoteSealer) {
    private val out = FileOutputStream(file)
    private val pending = ByteArray(sealer.chunkSize)
    private var pendingLength = 0
    var audioBytes = 0L
        private set

    init {
        out.write(sealer.header)
        out.flush()
    }

    fun append(data: ByteArray, length: Int) {
        var offset = 0
        while (offset < length) {
            val take = minOf(length - offset, sealer.chunkSize - pendingLength)
            System.arraycopy(data, offset, pending, pendingLength, take)
            pendingLength += take
            offset += take
            audioBytes += take
            if (pendingLength == sealer.chunkSize) writePending()
        }
    }

    private fun writePending() {
        out.write(sealer.seal(pending, pendingLength))
        out.flush()
        pendingLength = 0
    }

    /** Seals the last, shorter chunk and makes the file durable. */
    fun finish() {
        try {
            if (pendingLength > 0) writePending()
            out.fd.sync()
        } finally {
            out.close()
        }
    }

    /** Closes without sealing what is left; the caller deletes the file. */
    fun abort() {
        try { out.close() } catch (_: Exception) {}
    }
}
