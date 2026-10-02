import ProjectDescription

// The iOS mirror client. `make generate` turns this manifest into `ProwlMirror-iOS.xcodeproj`;
// the generated project is not in Git. Build settings are in `Config/*.xcconfig`.
// Target names and bundle identifiers are those of the imported project, so that a new
// build replaces the installed app.

func settings(_ name: String, productName: String) -> Settings {
  .settings(
    // Tuist changes "-" to "_" in the product name that it derives from the target name.
    base: ["PRODUCT_NAME": .string(productName)],
    configurations: [
      .debug(name: .debug, xcconfig: "Config/\(name).xcconfig"),
      .release(name: .release, xcconfig: "Config/\(name).xcconfig"),
    ],
    defaultSettings: .none
  )
}

let destinations: Destinations = [.iPhone, .iPad]

let project = Project(
  name: "ProwlMirror-iOS",
  options: .options(
    automaticSchemesOptions: .disabled,
    disableBundleAccessors: true,
    disableSynthesizedResourceAccessors: true
  ),
  settings: .settings(
    configurations: [
      .debug(name: .debug, xcconfig: "Config/Project-Debug.xcconfig"),
      .release(name: .release, xcconfig: "Config/Project-Release.xcconfig"),
    ],
    defaultSettings: .none
  ),
  targets: [
    .target(
      name: "ProwlMirror-iOS",
      destinations: destinations,
      product: .app,
      bundleId: "com.awhisper.ProwlMirror-iOS",
      infoPlist: nil,
      sources: ["../Shared/*.swift"],
      buildableFolders: ["ProwlMirror-iOS"],
      settings: settings("App", productName: "ProwlMirror-iOS")
    ),
    .target(
      name: "ProwlMirror-iOSTests",
      destinations: destinations,
      product: .unitTests,
      bundleId: "com.awhisper.ProwlMirror-iOSTests",
      infoPlist: nil,
      buildableFolders: ["ProwlMirror-iOSTests"],
      dependencies: [.target(name: "ProwlMirror-iOS")],
      settings: settings("Tests", productName: "ProwlMirror-iOSTests")
    ),
    .target(
      name: "ProwlMirror-iOSUITests",
      destinations: destinations,
      product: .uiTests,
      bundleId: "com.awhisper.ProwlMirror-iOSUITests",
      infoPlist: nil,
      buildableFolders: ["ProwlMirror-iOSUITests"],
      dependencies: [.target(name: "ProwlMirror-iOS")],
      settings: settings("UITests", productName: "ProwlMirror-iOSUITests")
    ),
  ],
  schemes: [
    .scheme(
      name: "ProwlMirror-iOS",
      buildAction: .buildAction(targets: ["ProwlMirror-iOS"]),
      testAction: .targets(
        [
          .testableTarget(target: "ProwlMirror-iOSTests", parallelization: .enabled),
          .testableTarget(target: "ProwlMirror-iOSUITests", parallelization: .enabled),
        ],
        configuration: .debug
      ),
      runAction: .runAction(configuration: .debug, executable: "ProwlMirror-iOS"),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(configuration: .release, executable: "ProwlMirror-iOS"),
      analyzeAction: .analyzeAction(configuration: .debug)
    )
  ]
)
