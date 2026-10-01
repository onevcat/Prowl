import Foundation
import Testing

@testable import supacode

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
}
