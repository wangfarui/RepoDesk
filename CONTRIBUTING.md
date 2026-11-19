# Contributing

RepoDesk is a native Swift 6 macOS application. Read `docs/architecture.md` for
the process, filesystem, persistence and language-service boundaries before
changing behavior. UI labels are currently primarily Simplified Chinese.

## Build and verify

Install a Swift 6 toolchain/macOS SDK (Xcode 16 or later) and Git. With full
Xcode and XcodeGen:

```sh
xcodegen generate
xcodebuild -project RepoDesk.xcodeproj -scheme RepoDesk -destination 'platform=macOS' -only-testing:RepoDeskTests test
```

The generated Xcode project is ignored. Change `project.yml`, then regenerate.
The test action uses a separate `Testing` configuration and application Bundle ID,
so the test host does not restore or write the normal app's workspace preferences.
Run the local verification gate before delivery:

```sh
./scripts/verify-local.sh
open build/RepoDesk.app
```

This runs strict concurrency checking, standalone functional/integration/rendering
checks, and builds, ad-hoc signs and validates the runnable application. Some
checks create temporary native windows and are intended for a logged-in desktop
session. Swift Testing unit tests run through Xcode; parsing their source during
local verification is not the same as executing them.

Bootstrap scripts use pinned upstream artifacts and hashes. Do not substitute
unverified downloads or add workstation-specific defaults. Read Maven paths from
workspace configuration, preserve preference keys and avoid writing into user
repositories during automatic refresh. Git writes require a user action.

Real-repository Push Diff checks require the explicit `REPODESK_VERIFY_WORKSPACE`,
`REPODESK_VERIFY_REPOSITORY`, `REPODESK_VERIFY_BRANCH` and `REPODESK_VERIFY_DIFF_PATH`
environment variables. An optional custom merge regression fixture can be selected
with `REPODESK_VERIFY_MERGE_FIXTURE`; its directory must contain `base.xml`,
`result.xml` and an `expected-bases.json` array of expected ancestor strings.
Default verification never implicitly loads a developer's private fixture directory.

## Changes and reports

Keep each change focused. Test behavior at the owning boundary, document any
compatibility implications, and include how the change was checked. Preserve
unrelated work already present in a contributor's checkout.

Report the macOS version, CPU architecture, RepoDesk version, reproduction steps,
expected result and actual result. Use a minimal sample repository where possible.
Remove private paths, company code, remote credentials and tokens from logs and
screenshots before sharing. Review `Support/ThirdParty/NOTICES.md` when changing
bundled components. Contributions to RepoDesk's own code use the project's MIT
license; third-party components retain their original licenses.
