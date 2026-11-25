package com.onevcat.prowl.mirror

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VaultTest {
    @Test
    fun staleRosterCannotRestoreAClearedAliasOrAnOlderCredential() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val testName = "mirror-vault-test-${uuid()}"
        val isolated = object : ContextWrapper(target) {
            override fun getSharedPreferences(name: String, mode: Int) =
                target.getSharedPreferences(testName, mode)
        }
        try {
            val vault = Vault(isolated)
            val original = Host("example.test", credential = Credential(uuid(), uuid(), "test"), name = "Alias")
            vault.save(original, replacingCredential = true)
            vault.rename(original.endpoint, null)
            vault.save(original.copy(lastConnectedAt = 123L), replacingCredential = false)
            assertNull(vault.hosts().single().name)
            assertEquals(123L, vault.hosts().single().lastConnectedAt)

            val replacement = original.copy(credential = Credential(uuid(), uuid(), "replacement"), name = null)
            vault.save(replacement, replacingCredential = true)
            vault.save(original.copy(lastConnectedAt = 456L), replacingCredential = false)
            val saved = vault.hosts().single()
            assertEquals(replacement.credential, saved.credential)
            assertEquals(123L, saved.lastConnectedAt)
            assertNull(saved.name)
        } finally {
            target.deleteSharedPreferences(testName)
        }
    }
}
