// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ProwlCLI",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(
      name: "prowl",
      targets: ["prowl"]
    )
  ],
  dependencies: [
    .package(name: "ProwlShared", path: "../Shared"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.13.1"),
    .package(url: "https://github.com/onevcat/Rainbow", from: "4.0.0"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
  ],
  targets: [
    .executableTarget(
      name: "prowl",
      dependencies: [
        .product(name: "ProwlCLIShared", package: "ProwlShared"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Rainbow", package: "Rainbow"),
      ]
    ),
    .target(
      name: "ProwlCLIContracts",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "ProwlCLITests",
      dependencies: [
        "ProwlCLIContracts",
        "prowl",
        .product(name: "ProwlCLIShared", package: "ProwlShared"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
        .product(name: "Yams", package: "Yams"),
      ]
    ),
  ]
)
