import Foundation
import YiTong

nonisolated enum DiffComparison: Equatable, Sendable {
  case workingTree
  case outgoing(GitOutgoingChangesComparison)
}

/// The user-facing mode of the diff window. `comparison` tracks what is
/// actually loaded; `mode` tracks intent, so an outgoing resolution failure
/// can keep the window in Outgoing mode showing the error while the switcher
/// remains usable.
nonisolated enum DiffMode: Equatable, Sendable {
  case uncommitted
  case outgoing
}

@Observable
@MainActor
final class DiffWindowState {
  /// Render phase of the current `diffDocument` in the WebView-backed
  /// `DiffView`. Rendering can take noticeably longer than the cache lookup for
  /// large files, since diffing/painting happens on the JS side; the phase is
  /// driven by the view's `didRender`/`didFail` events.
  enum RenderState: Equatable {
    case idle
    case rendering
    case failed(DiffError)

    var isFailed: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  var worktreeURL: URL?
  var branchName: String = ""
  private(set) var mode: DiffMode = .uncommitted
  var comparison: DiffComparison = .workingTree {
    didSet {
      if oldValue != comparison {
        onPresentationChange?()
      }
    }
  }
  var changedFiles: [DiffChangedFile] = []
  var selectedFile: DiffChangedFile?
  var diffDocument: DiffDocument?
  var isLoadingFiles = false
  var loadError: String?
  var renderState: RenderState = .idle
  /// Lets the window manager keep the window title in sync when the mode or
  /// the resolved outgoing base changes while the window stays open.
  var onPresentationChange: (@MainActor () -> Void)?
  /// Identity for the hosted `DiffView` (used as `.id()` by the view). YiTong
  /// skips re-rendering a value-equal document, so after a render failure the
  /// only way to retry the same content is to recreate the view; bumping this
  /// on retry (refresh or re-selecting the failed file) does exactly that.
  private(set) var renderGeneration = 0

  /// The current outgoing base, when an outgoing comparison is loaded. Drives
  /// the provenance UI (window title, file-list header, empty state).
  var outgoingBase: OutgoingBaseResolution? {
    if case .outgoing(let comparison) = comparison {
      return comparison.base
    }
    return nil
  }

  private var outgoingResolver: OutgoingComparisonResolver?
  private var documentCache: [String: DiffDocument] = [:]
  private var loadTask: Task<Void, Never>?
  private let selectDebouncer: Debouncer

  /// Upper bound for concurrent per-file document loads. Each load spawns two
  /// `git show` processes; outgoing diffs of long-lived branches can span
  /// hundreds of files, so the fan-out must not be unbounded.
  private static let maxConcurrentDocumentLoads = 6

  private let fetchChangedFiles: @Sendable (URL, DiffComparison) async throws -> [DiffChangedFile]
  private let loadDiffDocument: @Sendable (DiffChangedFile, URL, DiffComparison) async -> DiffDocument

  init(
    fetchChangedFiles: @escaping @Sendable (URL, DiffComparison) async throws -> [DiffChangedFile] =
      DiffWindowState.liveFetchChangedFiles,
    loadDiffDocument: @escaping @Sendable (DiffChangedFile, URL, DiffComparison) async -> DiffDocument = DiffWindowState
      .liveLoadDocument,
    selectDebounceInterval: Duration = .milliseconds(150),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.fetchChangedFiles = fetchChangedFiles
    self.loadDiffDocument = loadDiffDocument
    self.selectDebouncer = Debouncer(interval: selectDebounceInterval, clock: clock)
  }

  convenience init(
    fetchChangedFiles: @escaping @Sendable (URL) async -> [DiffChangedFile],
    loadDiffDocument: @escaping @Sendable (DiffChangedFile, URL) async -> DiffDocument,
    selectDebounceInterval: Duration = .milliseconds(150),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.init(
      fetchChangedFiles: { worktreeURL, _ in await fetchChangedFiles(worktreeURL) },
      loadDiffDocument: { file, worktreeURL, _ in await loadDiffDocument(file, worktreeURL) },
      selectDebounceInterval: selectDebounceInterval,
      clock: clock
    )
  }

  func load(
    worktreeURL: URL,
    branchName: String,
    comparison: DiffComparison = .workingTree,
    outgoingResolver: OutgoingComparisonResolver? = nil
  ) {
    self.worktreeURL = worktreeURL
    self.branchName = branchName
    self.comparison = comparison
    self.outgoingResolver = outgoingResolver
    mode =
      switch comparison {
      case .workingTree: .uncommitted
      case .outgoing: .outgoing
      }
    changedFiles = []
    selectedFile = nil
    diffDocument = nil
    loadError = nil
    documentCache = [:]
    selectDebouncer.cancel()
    loadTask?.cancel()
    loadTask = Task { await loadAllFiles(worktreeURL: worktreeURL, comparison: comparison) }
  }

  /// Whether the mode switcher should be offered; windows shown without an
  /// outgoing resolver (defensive default) stay single-mode.
  var canSwitchModes: Bool {
    outgoingResolver != nil
  }

  func setMode(_ newMode: DiffMode) {
    guard newMode != mode, let worktreeURL else { return }
    mode = newMode
    onPresentationChange?()
    selectDebouncer.cancel()
    loadTask?.cancel()
    changedFiles = []
    selectedFile = nil
    diffDocument = nil
    documentCache = [:]
    loadError = nil
    renderState = .idle
    isLoadingFiles = true
    switch newMode {
    case .uncommitted:
      comparison = .workingTree
      loadTask = Task { [weak self] in
        await self?.loadAllFiles(worktreeURL: worktreeURL, comparison: .workingTree)
      }
    case .outgoing:
      loadTask = Task { [weak self] in
        await self?.resolveAndLoadOutgoing(worktreeURL: worktreeURL)
      }
    }
  }

  func refresh() {
    guard let worktreeURL else { return }
    // Keep cache intact so file switching remains responsive during refresh
    loadTask?.cancel()
    isLoadingFiles = true
    loadError = nil
    switch mode {
    case .uncommitted:
      loadTask = Task { [weak self] in
        await self?.loadAllFiles(worktreeURL: worktreeURL, comparison: .workingTree)
      }
    case .outgoing:
      loadTask = Task { [weak self] in
        await self?.resolveAndLoadOutgoing(worktreeURL: worktreeURL)
      }
    }
  }

  /// Re-resolves the outgoing base from scratch (full ladder) and reloads.
  /// See `OutgoingComparisonResolver` for why resolution is never pinned.
  private func resolveAndLoadOutgoing(worktreeURL: URL) async {
    guard let outgoingResolver else {
      isLoadingFiles = false
      loadError = String(localized: "Outgoing changes are unavailable for this window.")
      return
    }
    do {
      let resolved = try await outgoingResolver()
      guard !Task.isCancelled else { return }
      comparison = .outgoing(resolved)
      await loadAllFiles(worktreeURL: worktreeURL, comparison: .outgoing(resolved))
    } catch {
      guard !Task.isCancelled else { return }
      changedFiles = []
      selectedFile = nil
      diffDocument = nil
      documentCache = [:]
      renderState = .idle
      isLoadingFiles = false
      loadError = error.localizedDescription
    }
  }

  func selectFile(_ file: DiffChangedFile) {
    // Re-selecting the current file is a no-op unless its render failed, in
    // which case it is the natural retry gesture.
    guard selectedFile != file || renderState.isFailed else { return }
    selectedFile = file

    // Leading-edge debounce: a deliberate selection applies immediately, but it
    // opens a window during which rapid follow-up selections are deferred — so
    // flicking through files (A -> B -> C) only renders the endpoints, never the
    // files the user just passed through.
    if selectDebouncer.isIdle {
      updateDiffDocument(documentCache[file.id])
      // Opens the coalescing window; nothing to re-apply when it closes.
      selectDebouncer.schedule {}
    } else {
      selectDebouncer.schedule { [weak self] in
        // The selection may have changed via a path other than `selectFile` while
        // the window was open (e.g. `loadAllFiles` reconciliation after a refresh)
        // — only apply the deferred document if `file` is still current.
        guard let self, self.selectedFile?.id == file.id else { return }
        self.updateDiffDocument(self.documentCache[file.id])
      }
    }
  }

  /// Called by the view once `DiffView` reports its `didRender` event.
  func markDiffRendered() {
    renderState = .idle
  }

  /// Called by the view once `DiffView` reports its `didFail` event, so the
  /// loading indicator doesn't stay stuck forever when a render fails.
  func markDiffFailed(_ error: DiffError) {
    renderState = .failed(error)
  }

  private func updateDiffDocument(_ newDocument: DiffDocument?) {
    if newDocument == diffDocument {
      // Re-applying an equal document is normally a no-op, but after a render
      // failure it means the user asked for a retry (refresh, or re-selecting
      // the failed file). YiTong won't re-render an equal document, so force
      // the view to be recreated instead.
      guard renderState.isFailed, newDocument != nil else { return }
      renderState = .rendering
      renderGeneration += 1
      return
    }
    renderState = newDocument != nil ? .rendering : .idle
    diffDocument = newDocument
  }

  // MARK: - Reconciliation (pure, testable without hitting Git or Task scheduling)

  /// Drops cache entries for files no longer present in the latest changed-file list.
  static func evictedCache(
    _ cache: [String: DiffDocument],
    keeping fileIDs: Set<String>
  ) -> [String: DiffDocument] {
    cache.filter { fileIDs.contains($0.key) }
  }

  /// Keeps the current selection if its document is cached; otherwise falls back to the
  /// first file, or to nothing if there are no files.
  static func resolvedSelection(
    current: DiffChangedFile?,
    files: [DiffChangedFile],
    cache: [String: DiffDocument]
  ) -> (file: DiffChangedFile?, document: DiffDocument?) {
    if let current, let document = cache[current.id] {
      return (current, document)
    } else if let first = files.first {
      return (first, cache[first.id])
    } else {
      return (nil, nil)
    }
  }

  // MARK: - Loading

  /// Exposed (not private) so tests can drive it directly with injected fakes,
  /// bypassing the `Task` scheduling used by `load()`/`refresh()`.
  func loadAllFiles(worktreeURL: URL, comparison: DiffComparison? = nil) async {
    let comparison = comparison ?? self.comparison
    isLoadingFiles = true
    loadError = nil
    let files: [DiffChangedFile]
    do {
      files = try await fetchChangedFiles(worktreeURL, comparison)
    } catch {
      guard !Task.isCancelled else { return }
      changedFiles = []
      selectedFile = nil
      diffDocument = nil
      documentCache = [:]
      renderState = .idle
      isLoadingFiles = false
      loadError = error.localizedDescription
      return
    }

    guard !Task.isCancelled else { return }

    changedFiles = files

    let fileIDs = Set(files.map(\.id))
    documentCache = Self.evictedCache(documentCache, keeping: fileIDs)

    // Load documents concurrently — bounded, and updating the cache as each
    // one completes so that file switching is responsive without waiting for
    // the whole set.
    await withTaskGroup(of: (String, DiffDocument).self) { [loadDiffDocument] group in
      var iterator = files.makeIterator()
      func addNextLoad() {
        guard let file = iterator.next() else { return }
        group.addTask {
          let doc = await loadDiffDocument(file, worktreeURL, comparison)
          return (file.id, doc)
        }
      }
      for _ in 0..<Self.maxConcurrentDocumentLoads {
        addNextLoad()
      }
      for await (id, doc) in group {
        guard !Task.isCancelled else {
          group.cancelAll()
          break
        }
        documentCache[id] = doc
        if selectedFile?.id == id {
          updateDiffDocument(doc)
        }
        addNextLoad()
      }
    }

    guard !Task.isCancelled else { return }
    isLoadingFiles = false

    let resolved = Self.resolvedSelection(current: selectedFile, files: files, cache: documentCache)
    selectedFile = resolved.file
    updateDiffDocument(resolved.document)
  }

  // MARK: - Live Git integration

  private nonisolated static func liveFetchChangedFiles(
    worktreeURL: URL,
    comparison: DiffComparison
  ) async throws -> [DiffChangedFile] {
    let gitClient = GitClient()
    switch comparison {
    case .workingTree:
      async let trackedOutput = gitClient.diffNameStatus(at: worktreeURL)
      async let untrackedPaths = gitClient.untrackedFilePaths(at: worktreeURL)
      let trackedFiles = DiffChangedFile.parseNameStatus(await trackedOutput)
      let untrackedFiles = await untrackedPaths.map {
        DiffChangedFile(status: .added, oldPath: nil, newPath: $0)
      }
      return trackedFiles + untrackedFiles

    case .outgoing(let revisions):
      let output = try await gitClient.outgoingDiffNameStatus(for: revisions, at: worktreeURL)
      return DiffChangedFile.parseNameStatus(output)
    }
  }

  private nonisolated static func liveLoadDocument(
    for file: DiffChangedFile,
    worktreeURL: URL,
    comparison: DiffComparison
  ) async -> DiffDocument {
    let gitClient = GitClient()
    let oldContents: String
    let newContents: String

    switch comparison {
    case .workingTree:
      switch file.status {
      case .added:
        oldContents = ""
        newContents = readFile(worktreeURL.appending(path: file.displayPath))
      case .deleted:
        oldContents = await gitClient.showFileAtHEAD(file.oldPath ?? "", in: worktreeURL) ?? ""
        newContents = ""
      case .renamed:
        oldContents = await gitClient.showFileAtHEAD(file.oldPath ?? "", in: worktreeURL) ?? ""
        newContents = readFile(worktreeURL.appending(path: file.newPath ?? ""))
      default:
        let path = file.displayPath
        oldContents = await gitClient.showFileAtHEAD(path, in: worktreeURL) ?? ""
        newContents = readFile(worktreeURL.appending(path: path))
      }

    case .outgoing(let revisions):
      switch file.status {
      case .added:
        oldContents = ""
        newContents = await gitClient.showFile(file.newPath ?? "", at: revisions.head, in: worktreeURL) ?? ""
      case .deleted:
        oldContents = await gitClient.showFile(file.oldPath ?? "", at: revisions.mergeBase, in: worktreeURL) ?? ""
        newContents = ""
      case .renamed, .copied:
        oldContents = await gitClient.showFile(file.oldPath ?? "", at: revisions.mergeBase, in: worktreeURL) ?? ""
        newContents = await gitClient.showFile(file.newPath ?? "", at: revisions.head, in: worktreeURL) ?? ""
      default:
        let path = file.displayPath
        oldContents = await gitClient.showFile(path, at: revisions.mergeBase, in: worktreeURL) ?? ""
        newContents = await gitClient.showFile(path, at: revisions.head, in: worktreeURL) ?? ""
      }
    }

    let diffFile = DiffFile(
      oldPath: file.oldPath,
      newPath: file.newPath,
      oldContents: oldContents,
      newContents: newContents,
    )
    return DiffDocument(files: [diffFile], title: file.displayName)
  }

  private nonisolated static func readFile(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }
}
