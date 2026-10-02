import Foundation
import Testing

@testable import supacode

struct WorktreeProjectKindTests {
  @Test(arguments: [
    (["App.xcodeproj/"], WorktreeProjectKind.apple),
    (["App.xcworkspace/"], WorktreeProjectKind.apple),
    (["Package.swift"], WorktreeProjectKind.apple),
    (["Project.swift"], WorktreeProjectKind.apple),
    (["settings.gradle"], WorktreeProjectKind.android),
    (["settings.gradle.kts"], WorktreeProjectKind.android),
    (["build.gradle.kts"], WorktreeProjectKind.android),
    (["gradlew"], WorktreeProjectKind.android),
    (["App.sln"], WorktreeProjectKind.dotnet),
    (["App.csproj"], WorktreeProjectKind.dotnet),
    (["pom.xml"], WorktreeProjectKind.java),
    (["go.mod"], WorktreeProjectKind.golang),
    (["Cargo.toml"], WorktreeProjectKind.rust),
    (["CMakeLists.txt"], WorktreeProjectKind.cpp),
    (["composer.json"], WorktreeProjectKind.php),
    (["Gemfile"], WorktreeProjectKind.ruby),
    (["pyproject.toml"], WorktreeProjectKind.python),
    (["requirements.txt"], WorktreeProjectKind.python),
    (["package.json"], WorktreeProjectKind.web),
  ])
  func detectsKindFromMarker(entries: [String], expected: WorktreeProjectKind) throws {
    try withTemporaryProjectDirectory(entries: entries) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == expected)
    }
  }

  @Test(arguments: [
    (["App.xcodeproj/", "package.json"], WorktreeProjectKind.apple),
    (["Package.swift", "package.json"], WorktreeProjectKind.apple),
    (["gradlew", "package.json"], WorktreeProjectKind.android),
    (["Cargo.toml", "package.json"], WorktreeProjectKind.rust),
    (["go.mod", "CMakeLists.txt"], WorktreeProjectKind.golang),
    (["composer.json", "package.json"], WorktreeProjectKind.php),
  ])
  func specificMarkersWinOverGenericOnes(entries: [String], expected: WorktreeProjectKind) throws {
    try withTemporaryProjectDirectory(entries: entries) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == expected)
    }
  }

  @Test func returnsNilWithoutMarkers() throws {
    try withTemporaryProjectDirectory(entries: ["README.md", "src/"]) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == nil)
    }
  }

  // MARK: - Flutter

  @Test func detectsFlutterFromPubspecWithFlutterKey() throws {
    try withTemporaryProjectDirectory(
      entries: ["ios/", "android/"],
      contents: [
        "pubspec.yaml": Data("name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n".utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .flutter)
    }
  }

  @Test func pureDartPubspecIsNotFlutter() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "pubspec.yaml": Data("name: pure\nenvironment:\n  sdk: ^3.0.0\n".utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == nil)
    }
  }

  @Test func flutterWinsOverNativeShellMarkers() throws {
    try withTemporaryProjectDirectory(
      entries: ["App.xcworkspace/", "gradlew"],
      contents: [
        "pubspec.yaml": Data("name: demo\nflutter:\n  uses-material-design: true\n".utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .flutter)
    }
  }

  // MARK: - React Native

  @Test func detectsReactNativeFromDependencyAndNativeShell() throws {
    try withTemporaryProjectDirectory(
      entries: ["android/"],
      contents: [
        "package.json": Data(#"{"dependencies":{"react-native":"0.80.0"}}"#.utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .reactNative)
    }
  }

  @Test func reactNativeDependencyWithoutNativeShellIsWeb() throws {
    try withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"dependencies":{"react-native":"0.80.0"}}"#.utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .web)
    }
  }

  @Test func oversizedPackageJSONIsNotParsedForReactNative() throws {
    // The dependency check must reject the file up front instead of
    // materializing hundreds of megabytes on the classification path.
    var oversized = #"{"dependencies":{"react-native":"0.80.0"},"padding":""#
    oversized += String(repeating: "x", count: 600 * 1024)
    oversized += #""}"#
    try withTemporaryProjectDirectory(
      entries: ["android/"],
      contents: [
        "package.json": Data(oversized.utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .web)
    }
  }

  @Test func plainPackageJSONWithNativeFoldersIsWeb() throws {
    try withTemporaryProjectDirectory(
      entries: ["ios/"],
      contents: [
        "package.json": Data(#"{"dependencies":{"react":"19.0.0"}}"#.utf8)
      ]
    ) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .web)
    }
  }

  // MARK: - Unity

  @Test func detectsUnityFromRootProjectVersion() throws {
    try withTemporaryProjectDirectory(
      entries: ["Assets/", "Assembly-CSharp.csproj", "App.sln"],
      contents: [
        "ProjectSettings/ProjectVersion.txt": Data("m_EditorVersion: 6000.4.5f1\n".utf8)
      ]
    ) { directory in
      // Unity generates root .sln/.csproj files; the Unity claim must
      // win over .NET.
      #expect(WorktreeProjectKind.detect(at: directory) == .unity)
    }
  }

  @Test func detectsUnityProjectOneLevelDown() throws {
    try withTemporaryProjectDirectory(
      entries: ["Gemfile", "Rakefile", "Source/"],
      contents: [
        "UniWebViewTest/ProjectSettings/ProjectVersion.txt": Data("m_EditorVersion: 6000.4.5f1\n".utf8)
      ]
    ) { directory in
      // SDK-style repo: tooling manifests at the root, the Unity test
      // project one folder down. Unity must win over Ruby.
      #expect(WorktreeProjectKind.detect(at: directory) == .unity)
    }
  }

  @Test func projectSettingsFolderAloneIsNotUnity() throws {
    try withTemporaryProjectDirectory(entries: ["ProjectSettings/", "go.mod"]) { directory in
      #expect(WorktreeProjectKind.detect(at: directory) == .golang)
    }
  }

  @Test func unityPrefersRider() {
    #expect(WorktreeProjectKind.unity.preferredActions.first == .rider)
    #expect(WorktreeProjectKind.unity.preferredActions.contains(.vscode))
  }

  @Test func hybridKindsPreferTheirDocumentedEditors() {
    #expect(WorktreeProjectKind.flutter.preferredActions.first == .androidStudio)
    #expect(WorktreeProjectKind.flutter.preferredActions.contains(.vscode))
    #expect(WorktreeProjectKind.reactNative.preferredActions.first == .cursor)
    #expect(WorktreeProjectKind.reactNative.preferredActions.contains(.webstorm))
    #expect(WorktreeProjectKind.reactNative.preferredActions.contains(.androidStudio))
  }

  @Test func returnsNilForMissingDirectory() {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "missing-\(UUID().uuidString)")
    #expect(WorktreeProjectKind.detect(at: directory) == nil)
  }
}
