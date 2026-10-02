package com.awhisper.prowlmirror

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

@Composable
internal fun PairingScanButton(connect: (Host, String) -> Unit, failed: (String) -> Unit) {
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { text ->
            try {
                val payload = PairingPayload.parse(text)
                connect(Host(payload.address, payload.port), payload.code)
            } catch (e: Exception) {
                failed(e.message ?: "Unable to read the pairing QR code")
            }
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            scanner.launch(ScanOptions().apply {
                setCaptureActivity(PairingCaptureActivity::class.java)
                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                setPrompt("Scan the QR code in Prowl Host → Add a Device")
                setBeepEnabled(false)
                setOrientationLocked(false)
            })
        } else {
            failed("Allow camera access in Settings, or enter the Host details manually")
        }
    }
    TextButton(onClick = { permission.launch(Manifest.permission.CAMERA) }) {
        Text("Scan QR Code")
    }
}
