# RepoDesk

RepoDesk is a local macOS workspace desk for reviewing and operating on source repositories without expanding into a full IDE.

## Language

**Workspace**:
A user-selected directory that can contain files and multiple registered Git repositories. A Workspace does not need to be a Git repository.
_Avoid_: Project, root repository

**Repository**:
A Git working tree registered inside the current Workspace. Git history, changes, branches, and write operations are always scoped to one Repository.
_Avoid_: Workspace repository, project

**Workspace Context**:
The application context for cross-repository overview, changes, files, and shared Maven settings. Cross-repository Changes are review-only and cannot create a Commit.
_Avoid_: Global repository

**Repository Context**:
The application context for one selected Repository, including Changes, Files, History, Maven, and explicit Git operations.
_Avoid_: Active Workspace

**Git Snapshot**:
The read model for a Repository's current branch, ahead/behind counts, working-tree changes, and latest Commit. Snapshots are refreshed automatically without performing Git writes.
_Avoid_: Repository registration, persisted Git state

**Change Selection**:
A versioned or unversioned file chosen for the next Commit. Excluding a Change Selection keeps that file out of the Commit.
_Avoid_: Review marker, viewed file

**Commit And Push**:
A two-phase user action that first creates a local Commit and then pushes it. A Push failure does not undo the Commit and can be retried without creating another Commit.
_Avoid_: Atomic commit-push

**Branch Operation**:
An explicit user-triggered Fetch, Pull, Push, Checkout, Merge, Rename, Delete, Abort Merge, or Continue Merge action against one Repository.
_Avoid_: Background refresh

**Maven Run**:
One explicit execution of a Maven Lifecycle goal for a selected Repository module, using Workspace-scoped Maven and JDK settings.
_Avoid_: Generic task
