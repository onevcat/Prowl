import Foundation

/// Project ecosystems Prowl can recognize from a worktree's top-level files,
/// used to pick a fitting app when the open action is set to Automatic.
enum WorktreeProjectKind: CaseIterable {
  case flutter
  case reactNative
  case unity
  case apple
  case android
  case dotnet
  case java
  case golang
  case rust
  case cpp
  case php
  case ruby
  case python
  case web

  /// Detects the project kind from a single shallow listing of `directory`.
  /// Checks run from the most specific marker to the least: `package.json` is
  /// last because nearly any repo can carry one for tooling, while an
  /// `.xcodeproj` or Gradle script identifies the project unambiguously.
  /// Flutter and React Native run first: their repos wrap native `ios/` /
  /// `android/` shells, so the hybrid kind is the more specific claim. Both
  /// require a positive manifest signal, not just a directory layout.
  static func detect(at directory: URL, fileManager: FileManager = .default) -> WorktreeProjectKind? {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return nil
    }
    let names = Set(entries.map { $0.lowercased() })
    func hasFile(withExtension ext: String) -> Bool {
      names.contains { $0.hasSuffix(".\(ext)") }
    }
    if names.contains("pubspec.yaml"), pubspecDeclaresFlutter(in: directory) {
      return .flutter
    }
    if names.contains("package.json"),
      names.contains("ios") || names.contains("android"),
      packageJSONDependsOnReactNative(in: directory)
    {
      return .reactNative
    }
    // Before the generic language markers: a Unity project generates
    // root-level `.sln`/`.csproj` files that would otherwise win as
    // .NET, and SDK-style repos (a Unity project one folder down next
    // to tooling manifests) would fall to whatever the tooling uses.
    if isUnityProject(entries: entries, names: names, in: directory, fileManager: fileManager) {
      return .unity
    }
    if hasFile(withExtension: "xcodeproj") || hasFile(withExtension: "xcworkspace")
      || names.contains("package.swift") || names.contains("project.swift")
    {
      return .apple
    }
    if names.contains("settings.gradle") || names.contains("settings.gradle.kts")
      || names.contains("build.gradle") || names.contains("build.gradle.kts")
      || names.contains("gradlew")
    {
      return .android
    }
    if hasFile(withExtension: "sln") || hasFile(withExtension: "csproj") {
      return .dotnet
    }
    if names.contains("pom.xml") {
      return .java
    }
    if names.contains("go.mod") {
      return .golang
    }
    if names.contains("cargo.toml") {
      return .rust
    }
    if names.contains("cmakelists.txt") {
      return .cpp
    }
    if names.contains("composer.json") {
      return .php
    }
    if names.contains("gemfile") {
      return .ruby
    }
    if names.contains("pyproject.toml") || names.contains("setup.py")
      || names.contains("requirements.txt") || names.contains("pipfile")
    {
      return .python
    }
    if names.contains("package.json") {
      return .web
    }
    return nil
  }

  /// Reads a bounded prefix of a marker file so detection stays cheap even
  /// when a repo carries a pathological manifest.
  nonisolated private static func markerFileContents(named name: String, in directory: URL) -> String? {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 128 * 1024) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// A `pubspec.yaml` alone is any Dart package; Flutter needs the
  /// `flutter:` key (dependency or top-level section) as positive proof.
  /// Internal because `RepositoryIconDetector` reuses the same signal.
  nonisolated static func pubspecDeclaresFlutter(in directory: URL) -> Bool {
    guard let contents = markerFileContents(named: "pubspec.yaml", in: directory) else {
      return false
    }
    return contents.contains(/^\s*flutter\s*:/.anchorsMatchLineEndings())
  }

  /// A Unity project is proven by `ProjectSettings/ProjectVersion.txt`
  /// — either at the root, or one level down, which covers SDK-style
  /// repos that keep the Unity test project next to tooling manifests
  /// (a `Gemfile` or `package.json` at the root must not outrank an
  /// actual Unity project). The nested pass is bounded and skips
  /// hidden entries.
  nonisolated private static func isUnityProject(
    entries: [String],
    names: Set<String>,
    in directory: URL,
    fileManager: FileManager
  ) -> Bool {
    func hasProjectVersion(in projectDirectory: URL) -> Bool {
      let versionFile =
        projectDirectory
        .appending(path: "ProjectSettings", directoryHint: .isDirectory)
        .appending(path: "ProjectVersion.txt", directoryHint: .notDirectory)
      return fileManager.fileExists(atPath: versionFile.path(percentEncoded: false))
    }
    if names.contains("projectsettings"), hasProjectVersion(in: directory) {
      return true
    }
    for entry in entries.sorted().prefix(50) where !entry.hasPrefix(".") {
      let child = directory.appending(path: entry, directoryHint: .isDirectory)
      if hasProjectVersion(in: child) {
        return true
      }
    }
    return false
  }

  /// React Native needs `react-native` as a declared dependency; the
  /// `ios`/`android` shell folders alone are checked by the caller.
  /// Internal because `RepositoryIconDetector` reuses the same signal.
  /// The read is bounded up front — a pathological multi-hundred-MB
  /// `package.json` must never be materialized on this path.
  nonisolated static func packageJSONDependsOnReactNative(in directory: URL) -> Bool {
    struct Manifest: Decodable {
      let dependencies: [String: String]?
      let devDependencies: [String: String]?
    }
    let limit = 512 * 1024
    let url = directory.appending(path: "package.json", directoryHint: .notDirectory)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1),
      data.count <= limit,
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else {
      return false
    }
    return manifest.dependencies?.keys.contains("react-native") == true
      || manifest.devDependencies?.keys.contains("react-native") == true
  }

  /// VS Code-style editors in `OpenWorktreeAction.editorPriority` order,
  /// used by the hybrid kinds whose tooling docs recommend VS Code.
  private static let vsCodeFamily: [OpenWorktreeAction] = [
    .cursor, .vscode, .windsurf, .vscodeInsiders, .vscodium,
  ]

  /// Apps to try before `OpenWorktreeAction.defaultPriority` when resolving
  /// the Automatic open action for this project kind.
  var preferredActions: [OpenWorktreeAction] {
    switch self {
    case .flutter: [.androidStudio, .intellij, .intellijEAP] + Self.vsCodeFamily
    case .reactNative: Self.vsCodeFamily + [.webstorm, .androidStudio]
    case .unity: [.rider] + Self.vsCodeFamily
    case .apple: [.xcode]
    case .android: [.androidStudio, .intellij, .intellijEAP]
    case .dotnet: [.rider]
    case .java: [.intellij, .intellijEAP]
    case .golang: [.goland]
    case .rust: [.rustrover]
    case .cpp: [.clion]
    case .php: [.phpstorm]
    case .ruby: [.rubymine]
    case .python: [.pycharm]
    case .web: [.webstorm]
    }
  }
}
