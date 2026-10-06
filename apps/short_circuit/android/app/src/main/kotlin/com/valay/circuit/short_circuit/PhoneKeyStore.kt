package com.valay.circuit.short_circuit

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The phone's recording key, kept where the recorder can reach it with no app running. The app
 * makes the key and hands it over; here it is sealed with a key that never leaves the Android
 * Keystore, the same protection the app's own copy has. Needed so the home-screen widget can
 * start a recording without opening the app.
 */
object PhoneKeyStore {
    private const val alias = "circuit_phone_key_wrap"
    private const val preferencesName = "circuit_phone_key"

    private fun wrapKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /** Keeps the key. Safe to call every time the app opens. */
    fun save(context: Context, keyId: Int, key: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        val sealed = cipher.doFinal(key)
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE).edit()
            .putInt("keyId", keyId)
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("sealed", Base64.encodeToString(sealed, Base64.NO_WRAP))
            .apply()
    }

    /** The key id and key, or null if none was handed over or it cannot be opened. */
    fun load(context: Context): Pair<Int, ByteArray>? = try {
        val prefs = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val keyId = prefs.getInt("keyId", 0)
        val iv = prefs.getString("iv", null)
        val sealed = prefs.getString("sealed", null)
        if (keyId == 0 || iv == null || sealed == null) {
            null
        } else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            val key = cipher.doFinal(Base64.decode(sealed, Base64.NO_WRAP))
            if (key.size == 32) keyId to key else null
        }
    } catch (_: Exception) {
        null
    }
}
