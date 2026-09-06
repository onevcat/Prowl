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

## Verification so far

- `make check`: all formatting/lint checks and 146 script tests pass.
- App Debug build and full App tests pass; no test filters were removed.
- CLI build, smoke, 233 unit tests and 110 integration tests pass.
- Simulated checkout restores unchanged input times without compiler misses. Changed and
  newly added invalid Swift files both fail compilation, rather than using stale outputs.
- An edited fixture reaches the built test bundle; restoring it restores the bundle content.
- The optional test build path is covered with the system Bash and with a path containing
  spaces. An injected Xcode failure still fails Make. This caught and fixed an empty-array
  expansion error under Bash `nounset` before publication.

Release output comparison and hosted cache-restoration checks remain to be completed.
