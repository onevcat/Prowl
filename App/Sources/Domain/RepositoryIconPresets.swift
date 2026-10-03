import Foundation

/// Repository-flavored SF Symbol picker presets. These are surfaced by
/// `RepositoryAppearancePickerView` (which reuses `TabIconPickerView`
/// with this list), distinct from the terminal-themed list the tab
/// picker ships. The split exists because the same picker is used in
/// two contexts that reach for different vocabulary: a tab picker
/// favors `play.fill` / `terminal` / `ladybug.fill`, a repo picker
/// favors `folder.fill` / `book.fill` / `hammer.fill`.
///
/// Order is loosely thematic so scanning the grid surfaces intent:
/// folders → boxes / data → docs / books → tools / dev → network →
/// art → nature / vibes.
///
/// All entries are restricted to SF Symbols 1–2 (macOS 11–12) baseline
/// so they're guaranteed-available on the project's macOS 26 minimum.
/// `.fill` variants are only listed when the symbol actually has one
/// (e.g. `rocket.fill` was tried but doesn't exist — only `rocket`
/// does, which renders as a question-mark placeholder if mistakenly
/// suffixed).
nonisolated enum RepositoryIconPresets {
  static let presets: [String] = [
    // Folders / containers (8)
    "folder.fill",
    "folder",
    "folder.badge.plus",
    "tray.fill",
    "tray.full.fill",
    "shippingbox.fill",
    "archivebox.fill",
    "externaldrive.fill",
    // Docs / books (6)
    "doc.fill",
    "doc.text.fill",
    "doc.richtext.fill",
    "book.fill",
    "books.vertical.fill",
    "bookmark.fill",
    // Tags / markers (3)
    "tag.fill",
    "flag.fill",
    "paperplane.fill",
    // Tools / dev (8)
    "hammer.fill",
    "wrench.fill",
    "wrench.and.screwdriver.fill",
    "screwdriver.fill",
    "gearshape.fill",
    "gear",
    "cpu",
    "ladybug.fill",
    // Network / web (4)
    "globe",
    "network",
    "server.rack",
    "cloud.fill",
    // Art (2)
    "paintpalette.fill",
    "paintbrush.fill",
    // Nature / symbols (9)
    "star.fill",
    "heart.fill",
    "leaf.fill",
    "bolt.fill",
    "sparkles",
    "flame.fill",
    "sun.max.fill",
    "moon.fill",
    "envelope.fill",
  ]
}
