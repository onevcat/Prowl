package com.awhisper.prowlmirror

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.gson.Gson
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Credentials never fall back to cleartext if Keystore or persistence fails. */
class Vault(context: Context) {
    private val prefs = context.getSharedPreferences("mirror-vault", Context.MODE_PRIVATE)
    private val alias = "prowl-mirror-devices"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            alias,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
            }
            .generateKey()
    }

    @Synchronized
    fun hosts(): List<Host> {
        val encoded = prefs.getString("hosts", null) ?: return emptyList()
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size >= 28) { "Saved Host credentials are damaged" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return Gson()
            .fromJson(
                String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8),
                Array<Host>::class.java,
            )
            .toList()
    }

    @Synchronized
    fun save(host: Host) {
        require(host.credential != null)
        val saved = hosts().filterNot { it.endpoint == host.endpoint } + host
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(Gson().toJson(saved.takeLast(64)).toByteArray())
        check(
            prefs.edit().putString("hosts", Base64.getEncoder().encodeToString(encrypted)).commit()
        ) {
            "Could not save Host credentials"
        }
    }
}
