import Foundation
import Testing

@testable import Prowl

/// The test host is the app, so `Bundle.main` carries the Info.plist that Launch Services reads.
struct WorkflowDocumentTypeTests {
  private static let identifier = "com.onevcat.prowl.workflow"

  @Test func exportedTypeIsAPackageForTheWorkflowExtension() throws {
    let exported = try #require(
      Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
    let type = try #require(exported.first { $0["UTTypeIdentifier"] as? String == Self.identifier })
    #expect(type["UTTypeConformsTo"] as? [String] == ["com.apple.package"])

    let tags = try #require(type["UTTypeTagSpecification"] as? [String: Any])
    let request = WorkflowStarterTemplate.Request(name: "Demo", id: "demo", icon: nil, kind: .singleAgent)
    let created = URL(filePath: request.fileName).pathExtension
    #expect(tags["public.filename-extension"] as? [String] == [created])
  }

  /// Prowl has no handler for an opened workflow. With any role other than `None`, a double-click
  /// in Finder brings Prowl forward and does nothing.
  @Test func documentTypeDoesNotClaimToOpenWorkflows() throws {
    let documents = try #require(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
    let document = try #require(
      documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(Self.identifier) == true })
    #expect(document["CFBundleTypeRole"] as? String == "None")
  }

  /// No icon file is bundled: Finder composes the icon from the app icon and this label.
  @Test func iconIsSystemGeneratedWithAWorkflowLabel() throws {
    let documents = try #require(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
    let document = try #require(
      documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(Self.identifier) == true })
    #expect(document["CFBundleTypeIconSystemGenerated"] as? Bool == true)

    let exported = try #require(
      Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
    let type = try #require(exported.first { $0["UTTypeIdentifier"] as? String == Self.identifier })
    let icons = try #require(type["UTTypeIcons"] as? [String: Any])
    #expect(icons["UTTypeIconText"] as? String == "Workflow")
  }
}
