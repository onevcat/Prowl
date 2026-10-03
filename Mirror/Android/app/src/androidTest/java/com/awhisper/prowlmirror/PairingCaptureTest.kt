package com.awhisper.prowlmirror

import android.Manifest
import android.content.res.Configuration
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import com.journeyapps.barcodescanner.ScanOptions
import com.journeyapps.barcodescanner.ViewfinderView
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingCaptureTest {
    @Test
    fun scannerUsesPortraitWithoutTheLaserOverlay() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val intent = ScanOptions()
            .setCaptureActivity(PairingCaptureActivity::class.java)
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setOrientationLocked(false)
            .createScanIntent(context)
        ActivityScenario.launch<PairingCaptureActivity>(intent).use { scenario ->
            scenario.onActivity { activity ->
                assertEquals(Configuration.ORIENTATION_PORTRAIT, activity.resources.configuration.orientation)
                val scanner = activity.findViewById<DecoratedBarcodeView>(
                    com.google.zxing.client.android.R.id.zxing_barcode_scanner,
                )
                assertNotNull(scanner)
                // ZXing exposes a setter only; inspect the resulting overlay state.
                val laser = ViewfinderView::class.java.getDeclaredField("laserVisibility")
                laser.isAccessible = true
                assertFalse(laser.getBoolean(scanner.viewFinder))
            }
        }
    }
}
