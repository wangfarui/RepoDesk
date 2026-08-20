# RepoDesk

RepoDesk is a native macOS workspace desk for reviewing Agent-produced repository changes, editing workspace files, performing explicit Git operations, and running Maven lifecycle goals. It is intentionally not an IDE and does not include language indexing, LSP, or debugging.

RepoDesk v0.1 connects workspace and nested-repository management, automatic multi-repository Git status, structured diff/history review with per-side Blame, selectable Commit and Commit And Push, repository Fetch/Pull/Push, Branch operations and merge-conflict resolution, editable workspace files, and an IDEA-style Maven module/lifecycle view with environment validation, final-command preview, process-group stopping, POM synchronization, streamed output, and recent-run replay. Workspace and Repository contexts expose different top-level modules. The staged implementation, replacement verification, and final user acceptance are complete.

## Requirements

- macOS 14+
- Xcode with the macOS SDK (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build and test with Xcode

```sh
xcodegen generate
xcodebuild -project RepoDesk.xcodeproj -scheme RepoDesk -configuration Debug build
xcodebuild -project RepoDesk.xcodeproj -scheme RepoDesk test
```

`RepoDesk.xcodeproj` is generated and intentionally ignored. Edit `project.yml`, then regenerate the project.

When only Apple Command Line Tools are available, build a directly runnable app bundle with:

```sh
./scripts/verify-local.sh
open build/RepoDesk.app
```

The verification script runs strict-concurrency type checking, parses the test sources, executes functional, integration, rendering, and repeatable performance fixtures, generates the app icon, builds `RepoDesk.app`, verifies version `0.1.0`, and checks the ad-hoc signature. It does not replace the XcodeGen test workflow when full Xcode and Swift Testing are installed.

The final local artifact is `build/RepoDesk.app`. Release contents, accepted replacement coverage, known limitations, and the App icon generation record are in `docs/release-v0.1.md`.

## Project map

- `RepoDeskApp/App` owns application lifecycle and in-memory shell state.
- `RepoDeskApp/Domain` holds value types with no UI concerns.
- `RepoDeskApp/Features` contains feature views; they depend on state through focused, explicit inputs.
- `RepoDeskApp/Repository` owns registration validation, persistence, directory selection, and filesystem discovery without invoking Git.
- `RepoDeskApp/Git` owns Git queries, parsing, and the bounded set of explicit v0.1 write operations.
- `RepoDeskApp/Files` owns lazy workspace browsing, optional compact single-child folder presentation, recursive debounced file-system monitoring, incremental tree refresh planning, filename search, block-level Markdown parsing, encoding-preserving document loading/saving, and external-write conflict detection.
- `RepoDeskApp/Maven` owns Workspace Maven/JDK settings and validation, multi-module POM scanning and refresh planning, lifecycle command construction, recent runs, log retention, and Maven presentation models.
- `RepoDeskApp/Settings` owns application-wide refresh, Files, and Diff preferences plus compatibility migration from legacy preference keys.
- `RepoDeskApp/Tasks` retains the reusable local task/process foundation and stops complete process groups; the v0.1 user-facing module is Maven rather than a generic Tasks editor.
- `RepoDeskApp/Process` and `RepoDeskApp/Diagnostics` own bounded command execution, cancellation, timeout handling, and rotating local diagnostics.
- `RepoDeskTests` tests domain and state behavior with Swift Testing.
- `Support/Resources` contains the 1024px App icon master and generated ICNS resource.
- `docs/architecture.md` defines the intended module seams for later milestones.

The original v0.1 product baseline is kept as the historical starting point in `docs/product-spec-v0.1.md`. User-approved file editing, Git Review, navigation, Maven, Blame, and explicit Git write-operation changes are recorded in `docs/product-spec-v0.1-amendment.md` and override conflicting baseline text.
Development and user acceptance proceed through the four large functional stages defined in `docs/product-acceptance-stages-v0.1.md`.
The current implementation and verification snapshot is summarized in `docs/v0.1-acceptance.md`.
