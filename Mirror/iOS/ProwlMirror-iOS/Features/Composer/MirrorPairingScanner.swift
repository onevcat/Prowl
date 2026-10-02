import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct MirrorPairingScanner: View {
  @Environment(\.dismiss) private var dismiss
  let scanned: (String) -> Void
  @State private var ready = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Group {
        if let error {
          ContentUnavailableView(
            "Camera unavailable", systemImage: "camera", description: Text(error))
        } else if ready {
          PairingCamera(scanned: scanned) { error = $0 }
        } else {
          ProgressView("Preparing camera…")
        }
      }
      .navigationTitle("Scan Host QR Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Cancel") { dismiss() } }
      .task {
        guard DataScannerViewController.isSupported else {
          error =
            "This device cannot scan QR codes. Enter the Host address, port and code manually."
          return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
          error = "Allow camera access in Settings, or enter the Host details manually."
          return
        }
        guard !Task.isCancelled else { return }
        guard DataScannerViewController.isAvailable else {
          error = "The camera is unavailable. Try again or enter the Host details manually."
          return
        }
        ready = true
      }
    }
  }
}

private struct PairingCamera: UIViewControllerRepresentable {
  let scanned: (String) -> Void
  let failed: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
      recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    guard !scanner.isScanning, !context.coordinator.finished else { return }
    do { try scanner.startScanning() } catch {
      let coordinator = context.coordinator
      Task { coordinator.fail(error.localizedDescription) }
    }
  }

  static func dismantleUIViewController(
    _ scanner: DataScannerViewController, coordinator: Coordinator
  ) {
    scanner.stopScanning()
    coordinator.finished = true
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let scanned: (String) -> Void
    let failed: (String) -> Void
    var finished = false

    init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
      self.scanned = scanned
      self.failed = failed
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !finished else { return }
      for item in addedItems {
        if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
          finished = true
          dataScanner.stopScanning()
          scanned(text)
          return
        }
      }
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
    ) {
      fail(error.localizedDescription)
    }

    func fail(_ message: String) {
      guard !finished else { return }
      finished = true
      failed(message)
    }
  }
}
