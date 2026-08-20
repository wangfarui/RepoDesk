# RepoDesk v0.1 local release record

## Release

- Version: `0.1.0`
- Bundle ID: `com.wangfarui.RepoDesk`
- Minimum system: macOS 14
- Final local artifact: `build/RepoDesk.app`
- Signing: ad-hoc local signature, verified with `codesign --verify --deep --strict`
- Status: released locally after final user acceptance on 2026-08-20

## Delivery contents

- Native Workspace and nested Repository management with restoration and precise FSEvents refresh.
- Files browsing, search, safe editing, conflict protection, and Markdown preview.
- Git Changes, History, Diff, per-side Blame, Commit/Push, remote operations, Branch operations, and merge-conflict resolution.
- Workspace Maven settings and Repository Maven module/lifecycle execution, process-group stop, output following, and recent-run replay.
- Central Settings with General, Files, Diff, and Maven areas; compact/wide and light/dark rendering evidence.
- One system-provided `Settings...` application-menu item; sidebar selection has no stale keyboard-focus border.
- Checked-in 1024px App icon master and generated ICNS resource.

## Verification

`./scripts/verify-local.sh` is the final local gate. It covers strict Swift concurrency type checking, test-source parsing, functional and rendering fixtures, real Git/FSEvents/Maven/process integration, state persistence/restoration, repeatable performance thresholds, application construction, version/icon checks, and signature verification.

The full Xcode/XcodeGen `xcodebuild test` workflow was not executed because the current machine does not have the required toolchain and disk budget. The user explicitly accepted the replacement verification for this local v0.1 delivery.

During the final restricted-sandbox rerun, the system rejected `FSEventStreamStart` and LaunchServices was unavailable. All verification before that point and every remaining fixture/build check passed independently. The same real FSEvents fixture passed earlier under host permissions, and the monitoring implementation was not changed during `REL-01`.

## App icon

- Built-in image generation mode was used.
- Final master: `Support/Resources/RepoDeskIcon-1024.png`
- Generated bundle resource: `Support/Resources/RepoDesk.icns`
- The generated image was normalized to 1024px and masked to the macOS rounded-square tile without changing the subject.
- Clean ImageIO thumbnails are combined into a multi-resolution TIFF and converted with Apple's `tiff2icns`; this avoids the incompatible small-size ICNS chunks produced by the earlier handwritten container.
- Internal `CFBundleVersion` is `2` so LaunchServices refreshes the icon metadata. The user-facing version remains `0.1.0` and does not display the build number.

Final prompt (selected candidate 1C):

```text
Use case: logo-brand
Asset type: refined macOS application icon candidate, square 1024x1024
Primary request: Refined final candidate 1C for RepoDesk
Subject: a single rounded ocean-teal file drawer with two cream folder cards and a clear mint branching path on the drawer front, ending in one coral node
Style/medium: premium semi-flat 3D macOS app icon, graphic and restrained, bright and highly legible
Composition/framing: centered straight-on three-quarter view, one clear drawer silhouette, generous padding, rounded-square canvas
Lighting/mood: soft controlled light, strong contrast and crisp broad edges for 16px and 32px recognition
Color palette: ocean teal, deep teal, mint green, coral, cream
Materials/textures: smooth matte surfaces, subtle bevels only, no brushed metal, no grain
Constraints: no text, no letters, no numbers, no watermark, no Apple/Git/Maven logos, no terminal, no monitor, no laptop, no keyboard, no multiple drawers, no tiny decorative elements
Avoid: photorealistic product rendering, low contrast, thin branch lines, busy shadows
```
