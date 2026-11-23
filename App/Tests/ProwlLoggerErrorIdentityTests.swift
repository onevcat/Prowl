import Foundation
import Testing

@testable import Prowl

struct ProwlLoggerErrorIdentityTests {
  @Test func cocoaErrorShowsDomainAndCode() {
    let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/private/secret"])

    #expect(ProwlLogger.errorIdentity(error) == "error_domain=NSCocoaErrorDomain error_code=513")
  }

  @Test func swiftErrorShowsTypeAndCaseWithoutItsData() {
    let identity = ProwlLogger.errorIdentity(ErrorIdentitySampleError.failed(output: "token=PRIVATE"))

    #expect(identity.hasPrefix("error_domain=ProwlTests.ErrorIdentitySampleError error_code="))
    #expect(!identity.contains("PRIVATE"))
  }
}

enum ErrorIdentitySampleError: Error {
  case failed(output: String)
}
