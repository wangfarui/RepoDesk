# RepoDesk

RepoDesk is a native macOS workspace desk for reviewing Agent-produced repository changes, editing workspace files, performing explicit Git operations, and running Maven lifecycle goals. It includes background Java indexing and source navigation through a managed language server, but is not a full IDE or debugger.

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

### Java navigation UI acceptance

Run `./scripts/verify-local.sh` to prepare the managed Java runtime and verify the local app, then generate/open `RepoDesk.xcodeproj`. In Xcode, select the `RepoDeskUIAcceptance` scheme with `My Mac` as the destination and choose Product → Test (`Command+U`). Run this in the logged-in macOS desktop session with Xcode automation access available; avoid interacting with the tested app while the suite runs.

The XCUITests in `RepoDeskUITests/JavaNavigationUITests.swift` exercise the real editor and Java language server:

- `Command+left click` on a class/type or a method invocation opens its definition, including return/parameter types.
- `Command+left click` on the method name at its declaration finds incoming call sites; multiple sites are offered for selection. No callers means no jump, not a fallback to the definition.
- Plain left click continues to place the caret/select text without navigation.
- `Command+B` always opens the definition, including when invoked on a method declaration; it never switches to callers.
- Source navigation vertically centers the target when the file has enough surrounding content; positions near a document boundary clamp to the available content.
- `Option+Command+B` offers implementations of the selected Java type or method and opens the selected source. `Option+Command+Return` remains an equivalent shortcut.
- `Command+U` opens a parent declaration, followed by back/forward navigation using `Option+Command+Left/Right`.
- `Command+O` and `Option+Command+O` search Java types and symbols and open their targets.

The suite creates a small temporary Java repository and isolated application preferences rather than using the user's Workspace. Search input is pasted literally so the active input method does not alter identifiers; the prior clipboard contents are restored if nothing else changes the clipboard. Failure screenshots and accessibility hierarchies are available in Xcode's test report. These UI tests complement, rather than replace, the functional/rendering checks and signed standalone app build in `verify-local.sh`.

The click rules above supersede the previous “Command+click always finds callers” behavior. The language server's hierarchical document symbols determine whether the click lies within a method name's `selectionRange`, rather than its whole signature/body or a matching word elsewhere. The current unsaved document is synchronized before resolving symbols. Incoming calls use their actual `fromRanges`, so navigation lands on the invocation, not the caller's method header. The JDT integration fixture also verifies overloads, annotated multiline signatures, return/parameter types and unsaved source changes.

### Java metadata location

RepoDesk starts JDT LS with `-Djava.import.generatesMetadataFilesAtProjectRoot=false`. Newly generated Eclipse metadata (`.project`, `.classpath`, `.factorypath`, and `.settings`) is redirected to the per-repository Java cache under `~/Library/Caches/RepoDesk/JavaLanguage/`, not written into the source repository. No repository `.gitignore` or Git-local ignore configuration is changed.

JDT LS continues to use metadata that already exists in the source repository; this setting does not migrate or delete it. Files generated by older RepoDesk builds must be inspected separately before any backup/removal, especially when a repository already tracks Eclipse configuration. Build-tool output such as Maven's `target/` is separate from Eclipse metadata and is not covered by this redirection. The real JDT integration verification checks that a fresh source fixture gains none of the four metadata entries and that its project/classpath metadata exists in the external cache.

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
