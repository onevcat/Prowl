import Foundation
import IdentifiedCollections

/// A book on the Shelf — the unified abstraction over a Git worktree or
/// a plain folder repository.
///
/// For worktrees the `id` is the underlying `Worktree.ID`. For plain
/// folders the `id` is the owning `Repository.ID`; plain folders are
/// represented in the terminal system as synthetic worktrees sharing the
/// repository's ID, so using the repository ID here keeps it consistent
/// with `selectedTerminalWorktree?.id`.
struct ShelfBook: Identifiable, Equatable, Hashable, Sendable {
  enum Kind: Equatable, Hashable, Sendable {
    case worktree
    case plainFolder
  }

  let id: Worktree.ID
  let repositoryID: Repository.ID
  let displayName: String
  /// Project/repository name shown as the primary part of the spine
  /// header. For plain folders this equals the folder name.
  let projectName: String
  let branchName: String?
  let kind: Kind

  var isPlainFolder: Bool { kind == .plainFolder }
}

extension RepositoriesFeature.State {
  /// Books rendered on the Shelf, in the same order the left navigation
  /// presents them (by repository, then by worktree rows within the
  /// repository). Plain folder repositories contribute a single book.
  ///
  /// The list is filtered to only books whose IDs are in
  /// `openedWorktreeIDs` — a worktree (or plain folder) appears on the
  /// Shelf only after the user has interacted with it at least once.
  /// Clicking a previously-unopened worktree in the left navigation
  /// while in Shelf mode adds its ID here, which causes its spine to
  /// materialize (with the standard spine-flow animation).
  /// Builds the ordered list of shelf books from current state.
  ///
  /// `customTitles` is an optional dictionary providing user-defined
  /// display names per repository. Defaults to empty for callers that
  /// don't care (e.g. legacy tests). The resolved `projectName` (and
  /// `displayName` for plain folders) prefers the custom title when
  /// present and falls back to `repository.name` otherwise.
  func orderedShelfBooks(
    customTitles: [Repository.ID: String] = [:]
  ) -> [ShelfBook] {
    // `ShelfView.body` re-runs on every TCA state change, so this method
    // is on the per-frame hot path. The previous implementation built a
    // a trapping dictionary initializer per call and routed worktree
    // ordering through `worktreeRowSections(in:)` — which constructs a
    // full `WorktreeRowModel` per worktree (PR/info lookups, icon
    // resolution, etc.) plus several intermediate `Set` allocations per
    // repository. None of that detail is needed by the Shelf, which only
    // consumes id/name/branch. Use direct `IdentifiedArray` lookup and
    // `orderedWorktrees(in:)` for the lighter ordering path.
    var books: [ShelfBook] = []
    for repositoryID in orderedRepositoryIDs() {
      guard let repository = repositories[id: repositoryID] else { continue }
      let projectName = customTitles[repositoryID] ?? repository.name
      if repository.kind == .plain {
        guard openedWorktreeIDs.contains(repository.id) else { continue }
        books.append(
          ShelfBook(
            id: repository.id,
            repositoryID: repository.id,
            displayName: projectName,
            projectName: projectName,
            branchName: nil,
            kind: .plainFolder
          ))
        continue
      }
      for worktree in orderedWorktrees(in: repository)
      where openedWorktreeIDs.contains(worktree.id) {
        books.append(
          ShelfBook(
            id: worktree.id,
            repositoryID: repositoryID,
            displayName: worktree.name,
            projectName: projectName,
            branchName: worktree.name,
            kind: .worktree
          ))
      }
      // Preserve prior behavior of `worktreeRowSections` which also
      // surfaced any pending (in-creation) worktrees that had been
      // marked opened. The list is typically empty so the cost is
      // negligible — the win is avoiding `makePendingWorktreeRow` which
      // builds a full `WorktreeRowModel` per entry.
      for pending in pendingWorktrees
      where pending.repositoryID == repositoryID
        && openedWorktreeIDs.contains(pending.id)
      {
        books.append(
          ShelfBook(
            id: pending.id,
            repositoryID: repositoryID,
            displayName: pending.progress.titleText,
            projectName: projectName,
            branchName: pending.progress.titleText,
            kind: .worktree
          ))
      }
    }
    return books
  }

  /// Identifier of the book currently open on the Shelf, derived from the
  /// active selection. Equal to `selectedTerminalWorktree?.id`, but kept as
  /// its own property so call sites read as shelf-aware.
  var openShelfBookID: Worktree.ID? {
    selectedTerminalWorktree?.id
  }

  /// The rendered book matching the current Shelf selection, if any.
  ///
  /// `openShelfBookID` can briefly point at a worktree/folder that has
  /// just been retired from `openedWorktreeIDs` after its last tab closes.
  /// Views should use this lookup rather than assuming a non-nil open ID
  /// means an open book is still present in `orderedShelfBooks()`.
  func openShelfBook(in books: [ShelfBook]) -> ShelfBook? {
    guard let openShelfBookID else { return nil }
    return books.first(where: { $0.id == openShelfBookID })
  }
}
