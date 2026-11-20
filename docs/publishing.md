# Publishing RepoDesk

The normal local build keeps the existing `com.wangfarui.RepoDesk` Bundle ID,
preference keys, workspace bookmarks, Maven configuration and history. Release
packaging operates on a temporary copy; it never signs or installs over the local
application. No script creates a GitHub repository or uploads a release.

## Prepare public source

1. Choose a project `LICENSE`; retain all third-party notices.
2. Review the diff, including pre-existing uncommitted changes, and run
   `./scripts/verify-local.sh`.
3. Run `python3 scripts/audit-publication.py --history`. This is a read-only,
   pattern-based check of the current files and every reachable historical blob;
   manually review company-specific examples, screenshots and logs as well.
4. If historical personal/company content must stay private, export a clean
   current snapshot with `python3 scripts/package-source.py`. Extract the archive
   into a separate directory and initialize a new public repository there. Keep
   the original local repository and its history intact. The archive includes
   current uncommitted changes, so review them before publication.

`build/`, application data, backups, generated Xcode projects and ignored local
configuration are excluded from the source archive. Never upload a directory
copied wholesale from the development machine. Do not rewrite existing history
or force-push as part of preparation without a separate decision.

## Prepare binary downloads

Build and package natively for Apple Silicon (`arm64`) and Intel (`x86_64`)
separately. Each package embeds a matching Temurin JRE. A universal app executable
alone does not make its bundled Java runtime universal.

```sh
./scripts/verify-local.sh
./scripts/package-release.sh --local
```

This creates an explicitly named `adhoc` ZIP and SHA-256 file in `build/releases`.
It is suitable for developer testing; it has not been notarized. Never present
that ZIP as a notarized public release. Confirm first-launch behavior on a clean
Mac, Git availability, Java navigation and Maven with user-selected paths.
Build metadata is checked for macOS 14.0, but testing on newer macOS versions
does not establish runtime acceptance on macOS 14 or on another architecture.

For public installation, use an Apple Developer ID Application certificate and
an existing `notarytool` keychain profile. Keep certificates and credentials out
of the repository and use your own local shell environment:

```sh
export REPODESK_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export REPODESK_NOTARY_PROFILE='your-notarytool-keychain-profile'
./scripts/package-release.sh --notarize
```

That explicit command signs nested native code and the copied app with the
hardened runtime, submits it to Apple's service, staples and validates the
ticket, and runs Gatekeeper assessment before creating the final ZIP. It does
not upload anything to GitHub. The signing/notarization branch requires your
certificate/profile and must be tested with them before a public binary release.
See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Attach the project license, third-party notices, corresponding upstream source
references and SHA-256 files to the release. Record which architecture and macOS
versions were actually tested. Keep release version/build numbers synchronized
between `Support/Info.plist` and `project.yml`.

## Local verification

Build, test and package locally using the commands above and the Xcode test
commands in the README. No GitHub Actions workflow is configured. UI tests
remain an interactive/local acceptance step. Verify macOS 14 support separately
on actual hardware or a VM, and test Apple Silicon and Intel builds separately.
