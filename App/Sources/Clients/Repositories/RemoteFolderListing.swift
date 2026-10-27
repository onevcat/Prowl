import Foundation

/// The subfolders of a folder on a host, as the folder browser of the Add Remote Folder
/// sheet shows them. Files are left out: only a folder can be added.
nonisolated struct RemoteFolderListing: Equatable, Sendable {
  nonisolated struct Entry: Equatable, Sendable, Identifiable {
    let name: String
    /// A Git repository (it has `.git`), or a bare repository.
    let isRepository: Bool
    /// False when the folder cannot be opened and listed.
    let isAccessible: Bool

    var id: String { name }
    var isHidden: Bool { name.hasPrefix(".") }
  }

  /// The folder, with links resolved.
  let path: String
  /// The host's home, with links resolved; nil when the host has no usable `$HOME`.
  let home: String?
  /// Sorted as Finder sorts names.
  let entries: [Entry]
  /// The subfolders that are not in `entries` because the folder has more than the limit.
  let omittedCount: Int

  /// Keeps a folder such as an expanded `node_modules` small enough for one reply.
  static let entryLimit = 2000

  /// `$1` is the path, `$2` the entry limit. The first lines are the folder and the home;
  /// each subfolder follows on its own line, with `g` for a repository or `x` for a folder
  /// that cannot be opened. A name with a newline is left out: no line can carry it.
  static let script = #"""
    case $1 in
      '~') prowl_path=$HOME ;;
      '~/'*) prowl_path=$HOME/${1#\~/} ;;
      *) prowl_path=$1 ;;
    esac
    [ -e "$prowl_path" ] || { printf 'PROWL_LIST\tmissing\n'; exit 0; }
    [ -d "$prowl_path" ] || { printf 'PROWL_LIST\tfile\n'; exit 0; }
    { cd -- "$prowl_path" 2>/dev/null && [ -r . ]; } || { printf 'PROWL_LIST\tinaccessible\n'; exit 0; }
    printf 'PROWL_LIST\tfolder\t%s\n' "$(pwd -P)"
    if [ -n "$HOME" ]; then
      printf 'PROWL_HOME\t%s\n' "$(cd -- "$HOME" 2>/dev/null && pwd -P)"
    fi
    prowl_count=0
    for prowl_name in * .[!.]* ..?*; do
      [ -d "$prowl_name" ] || continue
      case $prowl_name in *'
    '*) continue ;; esac
      prowl_count=$((prowl_count + 1))
      [ "$prowl_count" -le "$2" ] || continue
      prowl_flags=
      if [ -r "$prowl_name" ] && [ -x "$prowl_name" ]; then
        if [ -e "$prowl_name/.git" ]; then
          prowl_flags=g
        elif [ "$prowl_name" != .git ] && [ -f "$prowl_name/HEAD" ] && [ -d "$prowl_name/objects" ] \
          && [ -d "$prowl_name/refs" ]; then
          prowl_flags=g
        fi
      else
        prowl_flags=x
      fi
      printf 'PROWL_ENTRY\t%s\t%s\n' "$prowl_flags" "$prowl_name"
    done
    [ "$prowl_count" -le "$2" ] || printf 'PROWL_MORE\t%s\n' "$((prowl_count - $2))"
    """#

  /// Reads the output line by line: a name that is not UTF-8 cannot be sent back to the
  /// host as typed, so its line is left out, and the other lines keep their text. Lines
  /// before the folder line are startup output of the host's shell.
  static func parse(_ output: Data, path: String) throws -> RemoteFolderListing {
    var folder: String?
    var home: String?
    var entries: [Entry] = []
    var omittedCount = 0
    for line in output.split(separator: UInt8(ascii: "\n")) {
      guard let text = String(validating: line, as: UTF8.self) else { continue }
      let (tag, rest) = text.splittingAtFirstTab()
      switch tag {
      case "PROWL_LIST":
        let (kind, value) = rest.splittingAtFirstTab()
        switch kind {
        case "folder":
          guard RepositoryLocation.isCanonicalRemotePath(value) else { throw RemoteFolderValidationError.invalidPath }
          folder = value
        case "missing": throw RemoteFolderValidationError.folderNotFound(path)
        case "file": throw RemoteFolderValidationError.notAFolder(path)
        default: throw RemoteFolderValidationError.folderInaccessible(path)
        }
      case "PROWL_HOME" where folder != nil:
        home = RepositoryLocation.isCanonicalRemotePath(rest) ? rest : nil
      case "PROWL_ENTRY" where folder != nil:
        let (flags, name) = rest.splittingAtFirstTab()
        guard !name.isEmpty, !name.contains("/") else { continue }
        entries.append(Entry(name: name, isRepository: flags == "g", isAccessible: flags != "x"))
      case "PROWL_MORE" where folder != nil:
        omittedCount = Int(rest) ?? 0
      default:
        continue
      }
    }
    guard let folder else { throw RemoteRepositoryRefreshError.incompleteOutput }
    entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return RemoteFolderListing(path: folder, home: home, entries: entries, omittedCount: omittedCount)
  }
}

extension String {
  /// The text before the first tab and the text after it; the rest is empty without a tab.
  fileprivate nonisolated func splittingAtFirstTab() -> (String, String) {
    guard let tab = firstIndex(of: "\t") else { return (self, "") }
    return (String(self[..<tab]), String(self[index(after: tab)...]))
  }
}
