package com.awhisper.prowlmirror

import com.journeyapps.barcodescanner.CaptureActivity
import com.journeyapps.barcodescanner.DecoratedBarcodeView

class PairingCaptureActivity : CaptureActivity() {
    override fun initializeContent(): DecoratedBarcodeView =
        super.initializeContent().also { it.viewFinder.setLaserVisibility(false) }
}
