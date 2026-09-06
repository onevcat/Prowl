// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ProwlCLI",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .library(
      name: "ProwlCLIShared",
      targets: ["ProwlCLIShared"]
    ),
    .executable(
      name: "prowl",
      targets: ["prowl"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.13.1"),
    .package(url: "https://github.com/onevcat/Rainbow", from: "4.0.0"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
  ],
  targets: [
    .target(
      name: "ProwlCLIShared",
      dependencies: [
        .product(name: "Yams", package: "Yams"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
      ],
      path: "supacode/CLIService/Shared",
      exclude: ["Package.swift"]
    ),
    .executableTarget(
      name: "prowl",
      dependencies: [
        "ProwlCLIShared",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Rainbow", package: "Rainbow"),
      ],
      path: "ProwlCLI"
    ),
    .target(
      name: "ProwlCLIContracts",
      path: "ProwlCLIContracts",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "ProwlCLITests",
      dependencies: [
        "ProwlCLIContracts",
        "ProwlCLIShared",
        "prowl",
        .product(name: "JSONSchema", package: "swift-json-schema"),
        .product(name: "Yams", package: "Yams"),
      ],
      path: "ProwlCLITests"
    ),
  ]
)
