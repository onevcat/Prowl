package com.onevcat.prowl.mirror

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

/** Saved Hosts and the choices remembered with them. */
interface HostStore {
    fun hosts(): List<Host>
    fun save(host: Host, replacingCredential: Boolean)
    fun rename(endpoint: String, name: String?)
    fun forget(endpoint: String)
    var selectedEndpoint: String?
    var lastProfile: String?
}

/**
 * The saved Hosts after saving [host], or null when nothing changes. A roster connected with an
 * earlier key must not overwrite a new enrollment, and a rename made meanwhile wins.
 */
internal fun mergeSavedHost(entries: List<Host>, host: Host, replacingCredential: Boolean): List<Host>? {
    require(host.credential != null)
    val previous = entries.firstOrNull { it.endpoint == host.endpoint }
    if (!replacingCredential && previous?.credential != host.credential) return null
    val remembered = host.copy(
        name = if (previous == null) host.name else previous.name,
        hostName = host.hostName ?: previous?.hostName,
        lastConnectedAt = host.lastConnectedAt ?: previous?.lastConnectedAt,
        pairedAt = previous?.pairedAt ?: host.pairedAt,
    )
    return if (previous == null) listOf(remembered) + entries
    else entries.map { if (it.endpoint == host.endpoint) remembered else it }
}

/** Credentials never fall back to cleartext if Keystore or persistence fails. */
class Vault(context: Context) : HostStore {
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
    override fun hosts(): List<Host> {
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
    override fun save(host: Host, replacingCredential: Boolean) {
        mergeSavedHost(hosts(), host, replacingCredential)?.let(::write)
    }

    @Synchronized
    override fun rename(endpoint: String, name: String?) {
        write(hosts().map { if (it.endpoint == endpoint) it.copy(name = name) else it })
    }

    @Synchronized
    override fun forget(endpoint: String) {
        write(hosts().filterNot { it.endpoint == endpoint })
        if (selectedEndpoint == endpoint) selectedEndpoint = null
    }

    override var selectedEndpoint: String?
        get() = prefs.getString("selected-host", null)
        set(value) { prefs.edit().putString("selected-host", value).apply() }

    override var lastProfile: String?
        get() = prefs.getString("last-profile", null)
        set(value) { prefs.edit().putString("last-profile", value).apply() }

    private fun write(saved: List<Host>) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(Gson().toJson(saved).toByteArray())
        check(
            prefs.edit().putString("hosts", Base64.getEncoder().encodeToString(encrypted)).commit()
        ) {
            "Could not save Host credentials"
        }
    }
}
