import ProjectDescription

// The macOS app. `make generate` turns this manifest into `Prowl.xcodeproj`; the generated
// project is not in Git. Build settings are in `Config/Xcode/*.xcconfig`.

let configDirectory = "Config/Xcode"

func configurations(
  _ name: String,
  debug: SettingsDictionary = [:],
  release: SettingsDictionary = [:]
) -> [Configuration] {
  [
    .debug(name: .debug, settings: debug, xcconfig: "\(configDirectory)/\(name)-Debug.xcconfig"),
    .release(name: .release, settings: release, xcconfig: "\(configDirectory)/\(name)-Release.xcconfig"),
  ]
}

// Folders that the Makefile stages or that are submodules. Xcode copies each one into the
// app bundle as a folder. They must exist before generation (`make generate` checks this).
let bundledFolders = [
  "docs", "workflows", "skills", "ghostty", "terminfo", "git-wt", "prowl-cli", "agent-hooks",
]

let verifyGitWtScript = """
  WT_SCRIPT="${PROJECT_DIR}/Resources/git-wt/wt"
  if [ ! -f "$WT_SCRIPT" ]; then
    echo "error: Missing $WT_SCRIPT. Run: git submodule update --init Resources/git-wt" >&2
    exit 1
  fi
  if [ ! -x "$WT_SCRIPT" ]; then
    echo "error: $WT_SCRIPT is not executable." >&2
    exit 1
  fi
  """

let verifyEmbeddedToolsScript = """
  for TOOL in prowl-cli/prowl prowl-mirror-relay/prowl-mirror-relay; do
    BIN="${PROJECT_DIR}/Resources/$TOOL"
    if [ ! -x "$BIN" ]; then
      echo "error: Missing executable $BIN. Run: make embed-cli-debug" >&2
      exit 1
    fi
  done
  """

let project = Project(
  name: "Prowl",
  options: .options(
    automaticSchemesOptions: .disabled,
    defaultKnownRegions: ["en", "Base", "zh-Hans"],
    developmentRegion: "en",
    disableBundleAccessors: true,
    disableSynthesizedResourceAccessors: true
  ),
  packages: [
    .package(path: "supacode/CLIService/Shared"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.7.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", .exact("2.9.2")),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.10.1"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.0.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa/", from: "9.0.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.38.0"),
    .package(url: "https://github.com/onevcat/YiTong.git", from: "0.2.0"),
    .package(url: "https://github.com/onevcat/GlyphonKit.git", from: "0.1.0"),
  ],
  settings: .settings(configurations: configurations("Project"), defaultSettings: .none),
  targets: [
    .target(
      name: "supacode",
      destinations: .macOS,
      product: .app,
      productName: "Prowl",
      bundleId: "com.onevcat.prowl",
      infoPlist: .file(path: "supacode/Info.plist"),
      sources: ["MirrorClient/Shared/*.swift"],
      resources: .resources(bundledFolders.map { .folderReference(path: "Resources/\($0)") }),
      buildableFolders: [
        .folder(
          "supacode",
          exceptions: .exceptions([
            // `CLIService/Shared` is the `ProwlCLIShared` package, not app source.
            .exception(excluded: ["Info.plist", "CLIService/Shared"])
          ])
        )
      ],
      copyFiles: [
        .resources(
          name: "Embed mirror relay",
          subpath: "prowl-mirror-relay",
          files: [.glob(pattern: "Resources/prowl-mirror-relay/prowl-mirror-relay", codeSignOnCopy: true)]
        )
      ],
      scripts: [
        .pre(script: verifyGitWtScript, name: "Verify git-wt script", basedOnDependencyAnalysis: false),
        .pre(
          script: verifyEmbeddedToolsScript,
          name: "Verify prowl-cli binary",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: [
        .package(product: "ProwlCLIShared"),
        .package(product: "ComposableArchitecture"),
        .package(product: "Dependencies"),
        .package(product: "CasePaths"),
        .package(product: "Sentry"),
        .package(product: "PostHog"),
        .package(product: "Sparkle"),
        .package(product: "YiTong"),
        .package(product: "GlyphonKit"),
        .xcframework(path: "Frameworks/GhosttyKit.xcframework"),
        .sdk(name: "Carbon", type: .framework),
      ],
      settings: .settings(
        // Tuist derives the product name and the bundle identifier from the target, and its
        // values override the xcconfig files. The Debug app has its own name and identifier
        // so that it can be installed next to the release app.
        configurations: configurations(
          "App",
          debug: ["PRODUCT_NAME": "Prowl Debug", "PRODUCT_BUNDLE_IDENTIFIER": "com.onevcat.prowl.debug"]
        ),
        defaultSettings: .none
      )
    ),
    .target(
      name: "supacodeTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.onevcat.prowlTests",
      infoPlist: nil,
      // `Fixtures` goes into the test bundle as one folder, not as separate files.
      resources: [.folderReference(path: "supacodeTests/Fixtures")],
      buildableFolders: [
        .folder("supacodeTests", exceptions: .exceptions([.exception(excluded: ["Fixtures"])]))
      ],
      dependencies: [
        .target(name: "supacode"),
        .package(product: "DependenciesTestSupport"),
        .package(product: "OrderedCollections"),
        .package(product: "ProwlCLIShared"),
      ],
      settings: .settings(configurations: configurations("Tests"), defaultSettings: .none)
    ),
  ],
  schemes: [
    .scheme(
      name: "supacode",
      buildAction: .buildAction(targets: ["supacode"]),
      testAction: .targets(
        [.testableTarget(target: "supacodeTests", parallelization: .enabled)],
        configuration: .debug,
        // Tests assert on English copy.
        options: .options(language: "en", region: "US")
      ),
      runAction: .runAction(configuration: .debug, executable: "supacode"),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(configuration: .debug, executable: "supacode"),
      analyzeAction: .analyzeAction(configuration: .debug)
    )
  ]
)
