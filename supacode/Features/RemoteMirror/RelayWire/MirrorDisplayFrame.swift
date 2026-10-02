import Foundation

/// Host snapshots contain canonical, individually encoded DEC modes. A display
/// replica must not enable unsolicited reports: its PTY input goes back to Host.
public nonisolated enum MirrorDisplayFrame {
  public static func passiveSnapshot(_ snapshot: Data) -> Data {
    let bytes = Array(snapshot)
    var output = Data()
    var start = 0
    var index = 0
    while index + 8 <= bytes.count {
      if bytes[index] == 0x1B, bytes[index + 1] == 0x5B, bytes[index + 2] == 0x3F,
        bytes[index + 7] == 0x68,
        let digits = String(bytes: bytes[(index + 3)..<(index + 7)], encoding: .ascii),
        let mode = Int(digits),
        mode == 1004 || mode == 2031 || mode == 2048
      {
        output.append(contentsOf: bytes[start..<index])
        index += 8
        start = index
      } else {
        index += 1
      }
    }
    output.append(contentsOf: bytes[start...])
    return output
  }
}
