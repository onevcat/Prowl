import Foundation
import Testing

@testable import supacode

struct OpenWorktreeActionTests {
  @Test func menuOrderIncludesExpectedWorkspaceActions() {
    let settingsIDs = OpenWorktreeAction.menuOrder.map(\.settingsID)

    #expect(settingsIDs.contains("android-studio"))
    #expect(settingsIDs.contains("antigravity"))
    #expect(settingsIDs.contains("intellij"))
    #expect(settingsIDs.contains("rustrover"))
    #expect(settingsIDs.contains("vscode-insiders"))
    #expect(settingsIDs.contains("warp"))
    #expect(settingsIDs.contains("webstorm"))
    #expect(settingsIDs.contains("pycharm"))
  }

  @Test func menuOrderIncludesAllCases() {
    #expect(Set(OpenWorktreeAction.menuOrder) == Set(OpenWorktreeAction.allCases))
    #expect(OpenWorktreeAction.menuOrder.count == OpenWorktreeAction.allCases.count)
  }

  @Test func jetBrainsIDEsHaveCorrectBundleIdentifiers() {
    #expect(OpenWorktreeAction.androidStudio.bundleIdentifier == "com.google.android.studio")
    #expect(OpenWorktreeAction.intellij.bundleIdentifier == "com.jetbrains.intellij")
    #expect(OpenWorktreeAction.intellijEAP.bundleIdentifier == "com.jetbrains.intellij-EAP")
    #expect(OpenWorktreeAction.webstorm.bundleIdentifier == "com.jetbrains.WebStorm")
    #expect(OpenWorktreeAction.pycharm.bundleIdentifier == "com.jetbrains.pycharm")
    #expect(OpenWorktreeAction.rustrover.bundleIdentifier == "com.jetbrains.rustrover")
    #expect(OpenWorktreeAction.rider.bundleIdentifier == "com.jetbrains.rider")
    #expect(OpenWorktreeAction.goland.bundleIdentifier == "com.jetbrains.goland")
    #expect(OpenWorktreeAction.clion.bundleIdentifier == "com.jetbrains.CLion")
    #expect(OpenWorktreeAction.phpstorm.bundleIdentifier == "com.jetbrains.PhpStorm")
    #expect(OpenWorktreeAction.rubymine.bundleIdentifier == "com.jetbrains.rubymine")
  }

  @Test func newActionsHaveCorrectBundleIdentifiers() {
    #expect(OpenWorktreeAction.iterm2.bundleIdentifier == "com.googlecode.iterm2")
    #expect(OpenWorktreeAction.sublimeText.bundleIdentifier == "com.sublimetext.4")
    #expect(OpenWorktreeAction.tower.bundleIdentifier == "com.fournova.Tower3")
    #expect(OpenWorktreeAction.nova.bundleIdentifier == "com.panic.Nova")
    #expect(OpenWorktreeAction.zedPreview.bundleIdentifier == "dev.zed.Zed-Preview")
  }

  // Persisted in settings and kept byte-identical to upstream; intellijEAP intentionally
  // breaks the kebab-case convention.
  @Test func newActionsHaveStableSettingsIDs() {
    #expect(OpenWorktreeAction.zedPreview.settingsID == "zed-preview")
    #expect(OpenWorktreeAction.intellijEAP.settingsID == "intellijEAP")
    #expect(OpenWorktreeAction.nova.settingsID == "nova")
  }

  @Test func jetBrainsIDEsAreInEditorPriority() {
    let editors = OpenWorktreeAction.editorPriority
    #expect(editors.contains(.androidStudio))
    #expect(editors.contains(.intellij))
    #expect(editors.contains(.intellijEAP))
    #expect(editors.contains(.webstorm))
    #expect(editors.contains(.pycharm))
    #expect(editors.contains(.rustrover))
    #expect(editors.contains(.rider))
    #expect(editors.contains(.goland))
    #expect(editors.contains(.clion))
    #expect(editors.contains(.phpstorm))
    #expect(editors.contains(.rubymine))
  }

  @Test func channelVariantsFollowTheirStableEditors() throws {
    let editors = OpenWorktreeAction.editorPriority
    #expect(editors.contains(.nova))
    let zedIndex = try #require(editors.firstIndex(of: .zed))
    #expect(editors.firstIndex(of: .zedPreview) == zedIndex + 1)
    let intellijIndex = try #require(editors.firstIndex(of: .intellij))
    #expect(editors.firstIndex(of: .intellijEAP) == intellijIndex + 1)
  }

  @Test func projectKindsPreferMatchingSpecialistApps() {
    #expect(WorktreeProjectKind.apple.preferredActions.first == .xcode)
    #expect(WorktreeProjectKind.android.preferredActions == [.androidStudio, .intellij, .intellijEAP])
    #expect(WorktreeProjectKind.java.preferredActions == [.intellij, .intellijEAP])
    #expect(WorktreeProjectKind.dotnet.preferredActions.first == .rider)
    #expect(WorktreeProjectKind.golang.preferredActions.first == .goland)
    #expect(WorktreeProjectKind.rust.preferredActions.first == .rustrover)
  }

  @Test func preferredDefaultPicksXcodeForAppleProject() throws {
    try withTemporaryProjectDirectory(entries: ["Package.swift"]) { directory in
      let installed: Set<OpenWorktreeAction> = [.xcode, .cursor, .vscode, .finder]
      let action = OpenWorktreeAction.preferredDefault(for: directory) { installed.contains($0) }
      #expect(action == .xcode)
    }
  }

  @Test func preferredDefaultPicksAndroidStudioForGradleProject() throws {
    try withTemporaryProjectDirectory(entries: ["settings.gradle.kts", "gradlew"]) { directory in
      let installed: Set<OpenWorktreeAction> = [.androidStudio, .cursor, .xcode, .finder]
      let action = OpenWorktreeAction.preferredDefault(for: directory) { installed.contains($0) }
      #expect(action == .androidStudio)
    }
  }

  @Test func preferredDefaultPicksIntellijEAPWhenOnlyEAPInstalled() throws {
    try withTemporaryProjectDirectory(entries: ["build.gradle.kts"]) { directory in
      let installed: Set<OpenWorktreeAction> = [.intellijEAP, .cursor, .finder]
      let action = OpenWorktreeAction.preferredDefault(for: directory) { installed.contains($0) }
      #expect(action == .intellijEAP)
    }
  }

  @Test func preferredDefaultFallsBackToSecondSpecialistThenGenericPriority() throws {
    try withTemporaryProjectDirectory(entries: ["build.gradle.kts"]) { directory in
      let withIntellij: Set<OpenWorktreeAction> = [.intellij, .cursor, .finder]
      let intellijPick = OpenWorktreeAction.preferredDefault(for: directory) {
        withIntellij.contains($0)
      }
      #expect(intellijPick == .intellij)

      let withoutJetBrains: Set<OpenWorktreeAction> = [.cursor, .finder]
      let genericPick = OpenWorktreeAction.preferredDefault(for: directory) {
        withoutJetBrains.contains($0)
      }
      #expect(genericPick == .cursor)
    }
  }

  @Test func preferredDefaultIgnoresProjectKindWithoutMarkers() throws {
    try withTemporaryProjectDirectory(entries: ["README.md"]) { directory in
      let installed: Set<OpenWorktreeAction> = [.xcode, .vscode, .finder]
      let action = OpenWorktreeAction.preferredDefault(for: directory) { installed.contains($0) }
      #expect(action == .vscode)
    }
  }

  @Test func preferredDefaultWithoutDirectoryUsesGenericPriority() {
    let installed: Set<OpenWorktreeAction> = [.xcode, .zed, .finder]
    let action = OpenWorktreeAction.preferredDefault(for: nil) { installed.contains($0) }
    #expect(action == .zed)
  }

  @Test func preferredDefaultFallsBackToFinderWhenNothingInstalled() {
    let action = OpenWorktreeAction.preferredDefault(for: nil) { _ in false }
    #expect(action == .finder)
  }

}
