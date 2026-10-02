import Foundation
import Testing

@testable import supacode

struct AnalyticsContextTests {
  @Test func superPropertiesContainAllRequiredKeys() {
    let props = AnalyticsContext.superProperties

    let requiredKeys = [
      "app_version",
      "build_number",
      "os_version",
      "os_major",
      "os_minor",
      "device_model",
      "cpu_arch",
      "locale",
    ]

    for key in requiredKeys {
      #expect(props[key] != nil, "missing key: \(key)")
      #expect(!(props[key]?.isEmpty ?? true), "empty value for: \(key)")
    }
  }

  @Test func cpuArchHasExpectedValue() {
    let arch = AnalyticsContext.superProperties["cpu_arch"]
    #expect(["arm64", "x86_64", "unknown"].contains(arch))
  }

  @Test func osMajorAndMinorAreNumeric() {
    let props = AnalyticsContext.superProperties
    #expect(Int(props["os_major"] ?? "") != nil)
    #expect(Int(props["os_minor"] ?? "") != nil)
  }
}
