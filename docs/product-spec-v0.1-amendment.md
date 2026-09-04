# RepoDesk v0.1 product amendments

This amendment records user-approved changes made after visual acceptance of the runnable application. The original `product-spec-v0.1.md` remains intact as the migrated product baseline; the decisions below override conflicting Files, Git Review, Git safety, navigation, and Maven requirements.

## Replaced decision

The Files page is no longer read-only. Git review remains non-destructive by default, while the explicit user-triggered Git operations defined below are part of v0.1.

## Required editing behavior

- Normal text files open in a native monospaced editor with horizontal scrolling and no forced line wrapping.
- Edits are written back to disk automatically after a short debounce while preserving the detected encoding.
- Files opened from the tree, file-name search, or full-text search share the same multi-Tab surface.
- File Tabs keep their open order, Markdown mode, selected Tab, and visible line independently for the Workspace and each Repository; those sessions restore after relaunch.
- The maximum open Tab count is configurable, defaults to 5, and evicts the oldest Tab when exceeded.
- Saving after another process changes the file is rejected. The user must choose Reload or explicitly Overwrite.
- Markdown preview renders the current edit buffer rather than only the last disk version.
- Binary files are never editable. Files over 1 MB use read-only large-file mode; files over 10 MB are not loaded.
- Editing does not add IDE scope: no completion, indexing, LSP, refactoring, or debugger.

## Acceptance additions

1. A long source line remains one visual line and can be reached with horizontal scrolling.
2. Typing changes the buffer and shows an unsaved indicator.
3. Saving persists the edit and clears the unsaved indicator.
4. External modification cannot be overwritten without a specific confirmation.

## Git Review revision

- Review / viewed / unviewed markers and counters are removed. RepoDesk does not track manual file-review progress.
- Changes displays uncommitted work across all registered repositories.
- Changes hierarchy is Repository -> Changes or Unversioned Files -> Directory or Module.
- Changes contains every versioned working-tree change exactly once, regardless of index state. Unversioned Files contains files not yet tracked by Git. File rows still expose add, modify, delete, rename, copy, conflict, and binary states.
- Changes Diff compares HEAD directly with the current working file. A partially staged file does not appear twice and does not expose the index as a separate review version.
- Module grouping uses the nearest common module marker such as Maven, Gradle, Swift Package, Node package, or `project.yml`, with a top-level-directory fallback.
- History only displays the currently selected Repository.
- History supports Branch and User filters, a commit list, and selected-commit metadata, files, and Patch. Its changed-file list independently supports the same flat, Directory, Module, and Module-to-Directory grouping modes as Changes. A Merge Commit uses combined-diff file semantics: only files whose merge result differs from every parent are listed. A two-parent Merge displays a read-only IDEA-style Target Parent / Merge Result / Source Parent three-pane Diff; ordinary Commits remain Side-by-side.
- Selected File History is removed.

## Git Review acceptance additions

1. Changes can show multiple registered repositories without switching the active Repository.
2. Directory and Module grouping preserve Repository and Changes/Unversioned Files boundaries.
3. Rename and copy rows show their original/source paths; binary selection shows a clear Binary Diff state.
4. History never mixes commits from repositories other than the selected Repository.
5. Branch and User filters can be combined, and selecting a commit shows its metadata, changed files, and Patch; the changed-file grouping preference is persisted independently from Changes. Two-parent Merge Commits show combined files and a vertically aligned three-pane Diff, while merges with more than two parents surface an explicit unsupported state instead of an incorrect comparison.

## Git operations revision

- Repository Changes supports selecting the files included in the next Commit, entering a Commit message, creating a Commit, and running Commit And Push. Workspace Changes across all repositories remains review-only and cannot Commit.
- Commit And Push is a visible two-phase operation. If Commit succeeds and Push fails, the successful Commit remains recorded and the user can retry only the Push without creating another Commit.
- The Repository toolbar supports Fetch, Pull, Push, and explicit Stash/Unstash for the current Repository. Changes rows support explicit scoped Rollback; Background Snapshot refresh never performs these operations automatically.
- The searchable Branch picker supports local and remote Branches. A remote Branch can create or reuse its local tracking Branch; local Branches can be checked out, pushed, merged into the current Branch, renamed, safely deleted, and compared with the current Branch.
- Pull or Merge conflicts open an explicit conflict-resolution flow with current/incoming content, editable merge result, per-block or whole-file acceptance, Mark Resolved, Abort Merge, and Continue Merge.
- Side-by-side Diff can independently show Git Blame for the old and new side. Committed lines show author/date/hash information and working-tree-only lines show an uncommitted state.
- v0.1 does not expose Reset, Rebase, force Push, arbitrary Git commands, or automatic Git writes.

## Git operation safety and acceptance additions

1. Every Git write or remote operation requires a direct user action and is scoped to one Repository.
2. Excluding a file from Commit keeps that path out of the created Commit; rename selections include both source and destination paths.
3. Commit, Push, and Branch-operation progress and failures remain visible, and a failed Push never reports the preceding Commit as failed or silently creates a replacement Commit.
4. Remote Branch Checkout creates a tracking Branch when needed and rejects invalid remote HEAD selections.
5. Safe Branch Delete refuses unmerged Branches through normal Git semantics; destructive force-delete is not exposed.
6. Git commands use structured argument arrays, disable interactive terminal prompts, and redact Commit messages from surfaced command errors.
7. Conflict resolution writes only the explicit merge result selected by the user and stages the resolved path before Continue Merge.
8. Git Blame can be toggled independently for each Diff side without changing line alignment or the Diff result.

## Navigation and Maven revision

- The main modules move to the top of the window and depend on the selected context.
- Workspace shows Overview, Changes, Files, and Maven. Repository shows Changes, Files, History, and Maven.
- Overview exists only for Workspace. It keeps an empty state when no Git Repository is registered and owns the Repository discovery entry.
- Workspace Changes can display all registered repositories or one repository. Repository Changes is fixed to the current repository.
- Workspace Files uses the Workspace root. Repository Files uses the current Repository root.
- History exists only for Repository and uses an IDEA-style layout: selected-file Diff above, Commit list below-left, and changed-file list below-right. Ordinary Commits use Side-by-side Diff; two-parent Merge Commits use Target Parent / Merge Result / Source Parent three-pane Diff.
- The user-facing Tasks module is replaced by Maven. The generic task/process model can remain as an internal foundation, but v0.1 does not expose a separate generic task editor.
- Workspace Maven owns Maven Home, JDK/JAVA_HOME, User settings file, Local repository, and default parameters. Repository Maven owns module discovery and Lifecycle execution.
- Repository Maven presents clean, compile, package, install, and deploy; deploy requires confirmation. The Maven stage includes final-command preview, full process-group stopping, recent-run replay, log retention controls, and POM/Wrapper-driven project rescan.

## Git refresh acceptance additions

1. Selecting or restoring a Workspace automatically loads change counts for every registered Repository without requiring manual Repository selection.
2. Ordinary file events refresh only their containing Repository; a Workspace root file does not refresh all nested repositories.
3. A cached Repository background refresh does not replace its count, Changes list, or Diff with a visible loading state.
4. An unchanged snapshot does not trigger a visible rebuild. A transient refresh failure preserves the cached state.
