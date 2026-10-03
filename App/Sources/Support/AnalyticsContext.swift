import Darwin
import Foundation

/// Static metadata about the app and host machine. Registered once with PostHog
/// at startup so every event ships with these dimensions and dashboards can
/// slice by app version, OS, hardware, locale.
nonisolated enum AnalyticsContext {
  static var superProperties: [String: String] {
    let bundle = Bundle.main
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

    return [
      "app_version": appVersion,
      "build_number": buildNumber,
      "os_version": "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
      "os_major": "\(osVersion.majorVersion)",
      "os_minor": "\(osVersion.minorVersion)",
      "device_model": deviceModel,
      "cpu_arch": cpuArch,
      "locale": Locale.current.identifier,
    ]
  }

  private static var deviceModel: String {
    sysctlString("hw.model") ?? "unknown"
  }

  private static var cpuArch: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    let payload = bytes.prefix(while: { $0 != 0 })
    return String(bytes: payload, encoding: .utf8)
  }
}
