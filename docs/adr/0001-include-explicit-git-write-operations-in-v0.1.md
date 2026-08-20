---
status: accepted
---

# Include explicit Git write operations in v0.1

RepoDesk v0.1 includes user-triggered Commit, Push, Fetch, Pull, Branch Checkout, Merge, Rename, safe Delete, conflict resolution, and Merge Abort/Continue because repository review and the immediate follow-up operation form one daily workflow. Automatic Git snapshots and filesystem refreshes remain read-only, cross-repository Changes cannot Commit, and v0.1 does not expose Reset, Rebase, force Push, arbitrary Git commands, or automatic Git writes. Git arguments remain structured arrays, interactive terminal prompts are disabled, and partial success such as Commit succeeding before Push fails is preserved and shown explicitly instead of being treated as an atomic operation.
