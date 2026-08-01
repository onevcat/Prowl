import Foundation

nonisolated struct LineChangeBadgePresentation: Equatable, Sendable {
  let addedText: String
  let removedText: String
  let incompleteCountDescription: String?
  let accessibilityLabel: String

  init(
    addedLines: Int,
    removedLines: Int,
    skippedUntrackedFileCount: Int
  ) {
    removedText = "-\(removedLines)"
    guard skippedUntrackedFileCount > 0 else {
      addedText = "+\(addedLines)"
      incompleteCountDescription = nil
      accessibilityLabel = "\(addedLines) added lines, \(removedLines) removed lines"
      return
    }

    addedText = addedLines == 0 ? "+…" : "+\(addedLines)…"
    let fileNoun = skippedUntrackedFileCount == 1 ? "file was" : "files were"
    let omission = "\(skippedUntrackedFileCount) untracked \(fileNoun) not counted."
    incompleteCountDescription = "Addition count is incomplete because \(omission)"
    accessibilityLabel =
      "Addition count incomplete, \(addedLines) lines counted; \(omission) \(removedLines) removed lines."
  }
}
