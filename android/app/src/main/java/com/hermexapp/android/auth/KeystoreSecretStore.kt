package com.hermexapp.android.auth

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keystore-backed [SecretStore]: values are AES/GCM-encrypted with a
 * non-exportable key that lives in the Android Keystore, and the ciphertext
 * (iv + payload, base64) sits in a private SharedPreferences file. This is the
 * Android counterpart of the iOS Keychain wrapper — nothing sensitive is ever
 * written in plaintext, and the key never leaves secure hardware where present.
 *
 * (Jetpack Security's EncryptedSharedPreferences is deprecated, so this small
 * wrapper owns the Keystore directly — Android port plan §2.)
 */
class KeystoreSecretStore(context: Context) : SecretStore {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun save(value: String, key: SecretStore.Key, scope: String?) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = Base64.getEncoder().encodeToString(cipher.iv) +
            ":" + Base64.getEncoder().encodeToString(ciphertext)
        prefs.edit().putString(SecretStore.storageKey(key, scope), encoded).apply()
    }

    override fun load(key: SecretStore.Key, scope: String?): String? {
        val encoded = prefs.getString(SecretStore.storageKey(key, scope), null) ?: return null
        return try {
            val (ivPart, dataPart) = encoded.split(":", limit = 2).let { it[0] to it[1] }
            val iv = Base64.getDecoder().decode(ivPart)
            val data = Base64.getDecoder().decode(dataPart)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(data), Charsets.UTF_8)
        } catch (_: Exception) {
            // Corrupt entry or a key invalidated by the OS: treat as absent rather
            // than crash — the user just signs in again.
            null
        }
    }

    override fun delete(key: SecretStore.Key, scope: String?) {
        prefs.edit().remove(SecretStore.storageKey(key, scope)).apply()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val PREFS_NAME = "hermex_secrets"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "hermex_secret_store"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}
