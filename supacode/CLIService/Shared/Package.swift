// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ProwlShared",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ProwlCLIShared", targets: ["ProwlCLIShared"])
  ],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.13.1"),
  ],
  targets: [
    .target(
      name: "ProwlCLIShared",
      dependencies: [
        .product(name: "Yams", package: "Yams"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
      ],
      path: "."
    )
  ]
)
