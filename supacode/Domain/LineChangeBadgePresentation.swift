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
      accessibilityLabel = String(localized: "\(addedLines) added lines, \(removedLines) removed lines")
      return
    }

    addedText = addedLines == 0 ? "+…" : "+\(addedLines)…"
    let omission =
      if skippedUntrackedFileCount == 1 {
        String(localized: "\(skippedUntrackedFileCount) untracked file was not counted.")
      } else {
        String(localized: "\(skippedUntrackedFileCount) untracked files were not counted.")
      }
    incompleteCountDescription = String(localized: "Addition count is incomplete because \(omission)")
    accessibilityLabel = String(
      localized: "Addition count incomplete, \(addedLines) lines counted; \(omission) \(removedLines) removed lines."
    )
  }
}
