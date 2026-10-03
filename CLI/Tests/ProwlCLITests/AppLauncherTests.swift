@testable import prowl
import XCTest

final class AppLauncherTests: XCTestCase {
  func testProwlBundleIdentifierMatchingIncludesDebugBuild() {
    XCTAssertTrue(AppLauncher.isProwlAppBundleIdentifier("com.onevcat.prowl"))
    XCTAssertTrue(AppLauncher.isProwlAppBundleIdentifier("com.onevcat.prowl.debug"))
    XCTAssertFalse(AppLauncher.isProwlAppBundleIdentifier("com.example.Prowl"))
    XCTAssertFalse(AppLauncher.isProwlAppBundleIdentifier(nil))
  }
}
