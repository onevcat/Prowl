import Foundation

struct CanvasDirectoryShorteningPolicy: Sendable, Equatable {
  var shortenDirLength: Int
  var delimiter: String

  init(shortenDirLength: Int = 1, delimiter: String = "") {
    self.shortenDirLength = max(0, shortenDirLength)
    self.delimiter = delimiter
  }
}
