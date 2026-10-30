import AppKit
import GhosttyKit

/// What a clipboard confirmation asks the user to allow. libghostty decides
/// when a request needs confirmation (`clipboard-paste-protection`,
/// `clipboard-read`, and `clipboard-write`); Prowl only asks.
nonisolated enum GhosttyClipboardRequestKind: Equatable, Sendable {
  /// A paste that looks unsafe: line breaks outside a bracketed paste, or
  /// the bracketed paste end sequence.
  case paste
  case osc52Read
  case osc52Write
  case kittyRead
  case kittyWrite

  init?(_ request: ghostty_clipboard_request_e) {
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: self = .osc52Read
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: self = .osc52Write
    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: self = .kittyRead
    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: self = .kittyWrite
    default: return nil
    }
  }

  var messageText: String {
    switch self {
    case .paste:
      String(localized: "Paste Text That Can Run Commands?")
    case .osc52Read, .kittyRead:
      String(localized: "Allow a Program to Read the Clipboard?")
    case .osc52Write, .kittyWrite:
      String(localized: "Allow a Program to Write to the Clipboard?")
    }
  }

  var informativeText: String {
    switch self {
    case .paste:
      String(
        localized: """
          This text contains line breaks or a paste end sequence. If you paste it into a shell, \
          it can run commands immediately.
          """
      )
    case .osc52Read, .kittyRead:
      String(
        localized: """
          A program in this terminal asks for the clipboard contents. If you allow it, the program \
          receives the contents shown below.
          """
      )
    case .osc52Write, .kittyWrite:
      String(
        localized: """
          A program in this terminal asks to replace the clipboard contents with the text shown below.
          """
      )
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .paste: String(localized: "Paste")
    case .osc52Read, .osc52Write, .kittyRead, .kittyWrite: String(localized: "Allow")
    }
  }

  var cancelButtonTitle: String {
    switch self {
    case .paste: String(localized: "Cancel")
    case .osc52Read, .osc52Write, .kittyRead, .kittyWrite: String(localized: "Deny")
    }
  }
}

/// The part of a clipboard request that the confirmation shows. The request
/// completes with the original representations, not with this preview.
nonisolated struct GhosttyClipboardPreview: Equatable, Sendable {
  /// The longest text the dialog shows. A larger paste is cut, with a note
  /// that tells how much is not shown.
  static let maxDisplayedCharacters = 20000

  var text: String
  var imageData: Data?

  init(text: String, imageData: Data? = nil) {
    self.text = text
    self.imageData = imageData
  }

  /// Shows the `text/plain` representation when there is one, and else a
  /// summary line per representation. An image representation is shown as
  /// an image, so the user sees what a program would receive.
  init(contents: [GhosttyClipboardContent]) {
    let plain = contents.first { $0.mime == "text/plain" }.flatMap { String(bytes: $0.data, encoding: .utf8) }
    let summary = contents.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
    self.init(
      text: Self.displayText(plain ?? summary),
      imageData: contents.first { $0.mime.hasPrefix("image/") && !$0.data.isEmpty }?.data
    )
  }

  /// Makes control characters visible. An escape sequence or a lone carriage
  /// return is the part of a paste that does harm, and a text view would
  /// otherwise show it as nothing or as a line break.
  static func displayText(_ value: String) -> String {
    // A CR LF pair is an ordinary line break; only a lone CR is escaped.
    let scalars = Array(value.replacing("\r\n", with: "\n").unicodeScalars)
    var result = ""
    for scalar in scalars.prefix(maxDisplayedCharacters) {
      switch scalar.value {
      case 0x09, 0x0A:
        result.unicodeScalars.append(scalar)
      case 0x00...0x1F, 0x7F...0x9F, 0x2028...0x2029:
        result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    if scalars.count > maxDisplayedCharacters {
      let remaining = scalars.count - maxDisplayedCharacters
      result += "\n" + String(localized: "… \(remaining) more characters not shown")
    }
    return result
  }
}

/// One clipboard request that waits for the user. It resolves exactly once:
/// the first `allow` or `deny` runs the completion and later calls do nothing.
@MainActor
final class GhosttyClipboardConfirmation {
  let kind: GhosttyClipboardRequestKind
  let preview: GhosttyClipboardPreview
  /// True when libghostty can keep the decision as a session grant (a Kitty
  /// clipboard request with a password).
  let canRemember: Bool
  private var completion: ((_ allowed: Bool, _ remember: Bool) -> Void)?

  init(
    kind: GhosttyClipboardRequestKind,
    preview: GhosttyClipboardPreview,
    canRemember: Bool = false,
    completion: @escaping (_ allowed: Bool, _ remember: Bool) -> Void
  ) {
    self.kind = kind
    self.preview = preview
    self.canRemember = canRemember
    self.completion = completion
  }

  var isResolved: Bool { completion == nil }

  func allow(remember: Bool = false) {
    resolve(allowed: true, remember: canRemember && remember)
  }

  func deny() {
    resolve(allowed: false, remember: false)
  }

  private func resolve(allowed: Bool, remember: Bool) {
    guard let completion else { return }
    self.completion = nil
    completion(allowed, remember)
  }
}
