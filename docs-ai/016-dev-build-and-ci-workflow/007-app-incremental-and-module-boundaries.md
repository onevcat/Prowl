# 016.007 — App Incremental Builds and Module Boundaries

## Plan

Measure two independent changes on the same local Mac with fixed Xcode, paths and build
flags. Hosted CI checks cache restoration and test correctness; its elapsed time is not
used as a performance comparison. Transfer and decompression are outside this investigation.

1. Retain App incremental build state across checkout. Extend content-checked timestamp
   restoration to App inputs, and validate unchanged, edited, new, deleted and resource
   inputs against the actual build system before enabling it in CI. Scope state to the
   compiler, project, dependency and workspace identities. A miss must build normally.
2. Make the App consume the existing ProwlCLIShared library rather than compile its source
   files in the App module. Preserve isolation, visibility and static linkage. Compare
   cold builds, an App implementation edit and a Shared implementation edit before and
   after extraction. Keep the change only if measurements justify its maintenance cost.

Use the existing test surface to check behavior. Do not broadly expose internal declarations
or change test counts to make extraction compile. Check release output size and linkage.
Document failed approaches and retained results here once the experiments finish.

## Implementation decisions

The App uses a small package manifest in `supacode/CLIService/Shared/Package.swift` with
only Yams as a dependency. Referencing the root CLI package also resolved CLI-only packages
and added about 26 seconds before build activity locally. The CLI keeps its existing library
product and source path, and excludes the nested manifest from its source target.

The App synchronized source group treats Shared as an explicit folder and excludes that
folder from target membership. A directory membership exception alone did not exclude its
Swift children; the initial compiler errors exposed duplicate type definitions. The final
App Swift source list contains no Shared files. Imports make dependencies explicit. Only
`WorkflowValidator.isSingleLine`, already called by the App, needed public visibility.

App state is cached at a fixed CI DerivedData path. Its restore prefix includes the workspace,
Xcode build, Ghostty revision, project/package/build configuration and tracked input paths.
Added/deleted source or resource paths therefore start fresh instead of retaining stale
products. CLI-owned Shared timestamps are excluded from App timestamp restoration. Content
changes retain normal compiler/resource invalidation; the existing CAS remains available.

## Verification

- `make check`: all formatting/lint checks and 146 script tests pass.
- App Debug build and full App tests pass; no test filters were removed.
- CLI build, smoke, 233 unit tests and 110 integration tests pass.
- Universal Release builds successfully for arm64 and x86_64. Both executable UUIDs match
  the retained dSYM. Neither architecture adds a Shared dynamic library.
- Hosted cache-population [run 34003502189, attempt 1](https://github.com/onevcat/Prowl/actions/runs/34003502189/attempts/1)
  passes all checks and saves the new App incremental cache.
- Hosted [attempt 2](https://github.com/onevcat/Prowl/actions/runs/34003502189/attempts/2)
  restores that cache plus 943 unchanged App and 107 CLI input timestamps. All checks pass.
  App handwritten sources, Shared sources and test sources do not compile again. The sole
  Swift compile miss is `GeneratedAssetSymbols.swift`; module emission is a cache hit.
  CLI source compilation is also absent; SwiftPM still reports documentation plugin builds.
- Simulated checkout restores unchanged input times without compiler misses. Changed and
  newly added invalid Swift files both fail compilation, rather than using stale outputs.
- An edited fixture reaches the built test bundle; restoring it restores the bundle content.
- The optional test build path is covered with the system Bash and with a path containing
  spaces. An injected Xcode failure still fails Make. This caught and fixed an empty-array
  expansion error under Bash `nounset` before publication.

## Local measurements

Single paired samples on the same Mac, Xcode, paths and flags; these are not medians or
predictions of hosted CI elapsed time. The implementation-edit comparisons use warm CAS
and fresh DerivedData to isolate module extraction from retained incremental state.

| Build activity | Before extraction | After extraction |
| --- | ---: | ---: |
| Cold build-for-testing | 90.12 s | 73.46 s |
| App implementation edit | 38.54 s | 35.94 s |
| Shared implementation edit | 39.16 s | 21.64 s |

The Shared edit changes a control-character comparison to an equivalent expression. Before
extraction it misses 22 App compile tasks and one module task. After extraction it misses
12 Shared compile tasks and one Shared module task; App compilation is reused. This is the
strongest reason to retain the module boundary. App-only edits have a smaller benefit.

With retained incremental state, a simulated checkout plus a new App function-body edit
produced one compile miss and one module miss (21.14 s build activity). The Shared
implementation edit likewise produced one compile miss and one module miss (13.03 s). This was repeated
without driver diagnostic flags and with unique source content to avoid replaying an earlier
probe's exact cache entry. Earlier cache/state transitions produced broader recompilation;
this result describes a warm steady state, not an unconditional one-file rebuild guarantee.

Cache miss counters count compiler tasks, which may batch multiple source files. They are
not source-file counts. Restored incremental state and content-addressed cache reuse are
separate mechanisms. A warm cache does not guarantee narrow recompilation after every edit;
changes to public interfaces, dependency graphs or build flags can require broader work.

For a Release arm64 build with coverage disabled, identical optimization and stripping,
the main executable changes from 34,731,928 to 34,780,504 bytes: +48,576 bytes (+0.14%).
The Shared module is statically linked; `otool -L` reports no added Shared dynamic library.
This small size cost is accepted for the measured compilation isolation. These bytes must
not be mixed with older artifacts built under different coverage/build settings.

Raw logs, xcresult build metrics, paired binaries and probe scripts are under the ignored
`build/module-research/` directory. No release was published.
