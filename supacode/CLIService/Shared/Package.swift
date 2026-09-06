// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ProwlShared",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ProwlCLIShared", targets: ["ProwlCLIShared"])
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
  ],
  targets: [
    .target(
      name: "ProwlCLIShared",
      dependencies: [.product(name: "Yams", package: "Yams")],
      path: "."
    )
  ]
)
