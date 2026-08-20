# RepoDesk architecture

The v0.1 architecture keeps filesystem, Git, Maven/process, persistence, and document behavior behind typed boundaries rather than putting parsing or command construction directly in SwiftUI views. Later milestones should preserve and deepen these boundaries.

| Area | Responsibility | Boundary exposed to UI |
| --- | --- | --- |
| Workspace | Security-scoped directory access, recent workspaces, lazy file tree, filesystem monitoring | `WorkspaceStore` snapshots and commands |
| Repository registration | Per-workspace registrations, active selection, pin/order, manual selection and on-demand discovery | `RepositoryStoring`, `RepositoryPicking`, `RepositoryDiscovering` |
| GitRepository | System Git invocation, status/diff/history/Blame parsing, and explicit v0.1 Commit/remote/Branch/merge operations | `GitRepositoryReading`, `GitRepositoryOperating` |
| Maven / TaskRunner | Workspace Maven settings, POM module scanning and revision planning, lifecycle command construction, process-group execution, recent runs and log retention | `MavenSettingsStoring`, `MavenRunHistoryStoring`, `RepoTaskRunning` |
| DocumentEditor | Lazy file loading, filename search, encoding-preserving edits, conflict-safe saves, Markdown and large-file degradation | `WorkspaceFileBrowsing`, `WorkspaceFileSearching`, `DocumentLoading`, `DocumentSaving` |
| LocalSettings | Application-wide preferences plus Workspace-scoped persistence and restoration | `AppPreferencesStoring`, `SettingsStore`, `MavenSettingsStoring` |

Implementation details such as `Process`, `FileHandle`, `DispatchSource`, Git command strings, and configuration-file encoding stay behind those interfaces. UI receives immutable snapshots and sends user-intent commands; it should never parse Git output or assemble shell strings.

## Current milestone

`AppState` is the window-level coordinator for Workspace/Repository context, top navigation, selection restoration, Git snapshots, Files, History, and Maven execution presentation. The live app opens a workspace with `NSOpenPanel`, stores a security-scoped bookmark plus a path fallback in `UserDefaults`, and restores the most recently used workspace at launch. Preview-only factories still provide representative repository data without touching Git or Maven.

The native Settings scene and the in-window gear entry expose application-wide refresh, Files, and Diff preferences together with the current Workspace's Maven/JDK/settings and log policy. A fixed navigation rail keeps the four areas stable while each detail page owns its own scrolling, long-path behavior, and compact-window layout. The General page reads version and Bundle information from the running application. `AppPreferencesStoring` owns the application-wide values and migration of legacy Diff settings; Maven configuration remains Workspace-scoped through `MavenSettingsStoring`. Preference changes flow through `AppState`, so automatic file monitoring, foreground refresh, file-tree presentation, Markdown opening behavior, and new Changes Diffs update immediately.

Release resources have one checked-in 1024px PNG master under `Support/Resources`. `generate-app-icon.swift` creates the required ICNS representations without depending on Xcode, `project.yml` copies the same ICNS into XcodeGen builds, and `build-local.sh` embeds it before ad-hoc signing. RepoDesk displays version `0.1.0`; the direct-build `Info.plist` retains build metadata separately for macOS packaging, and the local verification gate checks the built bundle rather than trusting source configuration alone.

`WorkspaceWindowState` is the single persistence interface for Workspace-scoped interaction restoration. It stores navigation context, page, selected file and Markdown mode, Changes scope/grouping/file, History filters/Commit/file/split positions, and Maven module/Goal/recent-run selection. The UserDefaults adapter supplies defaults for older payloads, while `AppState` validates Repository identifiers before exposing restored state to views. Views report user selection through focused `AppState` methods and never write persistence directly.

Repository registration is intentionally separate from future Git snapshots. A registration contains only identity and presentation state: relative path, display name, pin, ordering, and active selection. Branch, changes, ahead/behind, and commit information belong to the Git read model and must not be persisted into registrations.

All process arguments remain arrays across the `CommandRunning` and `RepoTaskRunning` boundaries. `SystemGitRepositoryReader` owns read command formats and exposes typed snapshots, changes, history, branches, Commit details, Diffs, comparisons, and Blame. `SystemGitRepositoryOperator` owns the bounded write/remote command set for Commit, Fetch/Pull/Push, Branch operations, Merge, and conflict resolution. SwiftUI sends user intents through these interfaces and never assembles Git commands. Read commands use bounded timeouts; write/remote commands disable terminal prompts and surface explicit operation states. Maven/task execution uses `posix_spawn` with a dedicated process group, streams stdout/stderr, sends `SIGTERM` to the group on Stop, and escalates to `SIGKILL` after two seconds. The user-facing v0.1 surface is Maven; the generic task model remains an internal reusable foundation.

Git background behavior and Git operations are deliberately separate. Workspace opening, FSEvents, and repository refreshes can only request read models. A Commit is available only when Changes is scoped to one Repository; Commit And Push preserves Commit success if the later Push fails and supports retrying only the Push. Branch and merge operations are available only in Repository context, and conflict resolution requires an explicit edited result before staging the resolved path.

`MavenCommandBuilder` owns wrapper/Home/system Maven resolution and typed argument/environment construction. `MavenRunHistoryStoring` persists Workspace-scoped records and applies count/log-size policies; records keep executable, arguments, working directory, result and the explicit `JAVA_HOME` override, but never persist the full inherited process environment. `MavenProjectRefreshPlanner` maps file batches to Maven revisions only for full rescans or Repository-local `pom.xml`/Wrapper changes. SwiftUI rescans off the main actor and keeps the existing module tree visible until a replacement is ready.

The editor surface is an AppKit `NSTextView` wrapped for SwiftUI. Its text container has an unbounded horizontal size, so source and diff lines scroll instead of collapsing into a narrow SwiftUI layout proposal. `AppState` owns only the active edit buffer and user intents; `FileSystemDocumentStore` owns decoding, encoding, revisions, atomic writes, and external-modification rejection.

The same native text surface exposes an optional tail-follow binding for streamed output. Output callbacks are coalesced to at most one pending UI flush, and a stable run identity lets the editor append only the new `NSTextStorage` suffix instead of rescanning and restyling the full log. Switching runs, selecting history, clearing output, or changing style still performs a full replacement. The coordinator observes clip-view bounds changes: reaching the tail enables following, scrolling upward disables it, and programmatic replacement preserves the current viewport while paused. Maven owns the user-facing jump-to-latest control; historical logs do not opt into tail following.

Workspace changes are delivered by `SystemWorkspaceChangeMonitor` through recursive FSEvents. The monitor coalesces bursts before emitting typed batches, preserves exact ordinary file paths, and maps relevant `.git` metadata to its Repository root. `WorkspaceChangeScope` standardizes each changed path once per batch and reuses that scope for Repository and Maven-project matching. `WorkspaceTreeRefreshPlanner` maps each batch to the loaded directory snapshots and registered repositories that can actually be affected. Repository matching is one-way from the changed path into the Repository, so a Workspace root file does not invalidate every nested Repository. Directory enumeration failures remain explicit state with a retry command.

Repository snapshots are loaded at the Root level whenever the Workspace or registered Repository set changes, independent of the selected page. Cross-repository work is limited to four concurrent snapshots and overlapping requests for the same Repository share one operation. Initial loads may expose a spinner; cached background refreshes preserve the visible count/list/Diff and only publish materially changed snapshots.

Markdown preview uses `MarkdownPreviewParser` to convert the current edit buffer into typed block-level structures before SwiftUI rendering. Headings, paragraphs, lists, task items, quotes, fenced code, thematic breaks, and basic tables are rendered as separate native views; Foundation's Markdown `AttributedString` parser remains responsible for inline emphasis, links, and code spans.

## Safety invariants

- Automatic Git refreshes remain read-only; every Git write or remote operation requires an explicit user action against one Repository.
- v0.1 exposes only the defined Commit, Fetch/Pull/Push, Checkout, Merge, Rename, safe Delete, and conflict-resolution operations. Reset, Rebase, force Push, arbitrary Git commands, and automatic Git writes remain out of scope.
- Git arguments remain structured arrays, terminal prompts are disabled for app-triggered operations, and Commit messages are redacted from surfaced command failures.
- Commit And Push is not treated as atomic: a Push failure preserves the created Commit and retrying Push never creates a second Commit.
- File saves preserve the detected encoding and compare a content revision before writing; overwriting an externally changed file requires an explicit user action.
- Binary files and files larger than the editor threshold are never edited.
- Task arguments remain an array passed to `Process`; never concatenate a shell command.
- Maven reads Repository POM files and an optional Maven Wrapper only to build explicit user-triggered lifecycle commands; repository-provided generic task import is not implemented.
- Maven history never persists the complete inherited environment; replay merges the saved `JAVA_HOME` override into the current process environment.
- Maven project rescans are limited to POM/Wrapper changes and atomically replace the visible module tree.
- Workspace FSEvents refresh every registered Repository actually affected by a batch, including unselected repositories, while avoiding unrelated repositories.
- Cached Git data remains visible during background refresh failure; Git commands have a bounded timeout and cancellation terminates the running process.
