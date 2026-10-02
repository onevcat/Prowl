// swift-tools-version: 6.2

import PackageDescription

// The relay process that the macOS app starts for Remote Mirror, and its wire types.
// The app also compiles the `MirrorRelayProtocol` sources into its own module.
let package = Package(
  name: "ProwlMirrorRelay",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "prowl-mirror-relay", targets: ["prowl-mirror-relay"])
  ],
  targets: [
    .target(name: "MirrorRelayProtocol"),
    .executableTarget(name: "prowl-mirror-relay", dependencies: ["MirrorRelayProtocol"]),
    .testTarget(name: "MirrorRelayTests", dependencies: ["MirrorRelayProtocol", "prowl-mirror-relay"]),
  ]
)
