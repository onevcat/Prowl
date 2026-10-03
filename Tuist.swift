import Foundation
import ProjectDescription

// `tuist generate` resolves Swift packages. Use the checkout directory that the Makefile
// passes to `xcodebuild`, so that generation and builds share one copy.
let packageCheckouts = NSHomeDirectory() + "/Library/Caches/supacode-spm-cache/SourcePackages"

let tuist = Tuist(
  project: .tuist(
    compatibleXcodeVersions: .all,
    swiftVersion: "6.0",
    generationOptions: .options(
      includeGenerateScheme: false,
      additionalPackageResolutionArguments: ["-clonedSourcePackagesDirPath", packageCheckouts]
    )
  )
)
