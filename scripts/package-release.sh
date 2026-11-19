#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
mode="${1:---local}"
if [[ "${mode}" != "--local" && "${mode}" != "--notarize" ]]; then
  echo "Usage: $0 [--local|--notarize]" >&2
  exit 2
fi
if [[ "${mode}" == "--notarize" ]]; then
  : "${REPODESK_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
  : "${REPODESK_NOTARY_PROFILE:?Set an existing notarytool keychain profile}"
  [[ -s "${project_dir}/LICENSE" ]] || { echo "Choose a project license before public distribution" >&2; exit 1; }
fi
source_app="${project_dir}/build/RepoDesk.app"
"${script_dir}/verify-app-bundle.sh" "${source_app}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${source_app}/Contents/Info.plist")"
build_arch="$(lipo -archs "${source_app}/Contents/MacOS/RepoDesk")"
release_dir="${project_dir}/build/releases"
mkdir -p "${release_dir}"
staging="$(mktemp -d "${release_dir}/.package.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT
app="${staging}/RepoDesk.app"
ditto "${source_app}" "${app}"
suffix="adhoc"
if [[ "${mode}" == "--notarize" ]]; then
  # Sign nested native code before its containing bundles. Never alter the local app.
  while IFS= read -r -d '' native_file; do
    if file -b "${native_file}" | grep -q 'Mach-O'; then
      if [[ "${native_file:t}" == "java" ]]; then
        codesign --force --options runtime --timestamp --sign "${REPODESK_SIGNING_IDENTITY}" \
          --entitlements "${project_dir}/Support/Release/Java.entitlements" "${native_file}"
      else
        codesign --force --options runtime --timestamp --sign "${REPODESK_SIGNING_IDENTITY}" "${native_file}"
      fi
    fi
  done < <(find "${app}/Contents/Resources" -type f -print0)
  while IFS= read -r nested_bundle; do
    codesign --force --options runtime --timestamp --sign "${REPODESK_SIGNING_IDENTITY}" "${nested_bundle}"
  done < <(find "${app}/Contents/Resources" -depth -type d \( -name '*.bundle' -o -name '*.framework' -o -name '*.app' -o -name '*.jre' \))
  codesign --force --options runtime --timestamp --sign "${REPODESK_SIGNING_IDENTITY}" \
    --entitlements "${project_dir}/Support/Release/Java.entitlements" \
    "${app}/Contents/Resources/JavaLanguage/jre"
  codesign --force --options runtime --timestamp --sign "${REPODESK_SIGNING_IDENTITY}" "${app}"
  codesign --verify --deep --strict "${app}"
  ditto -c -k --keepParent "${app}" "${staging}/submission.zip"
  xcrun notarytool submit "${staging}/submission.zip" --keychain-profile "${REPODESK_NOTARY_PROFILE}" --wait
  xcrun stapler staple "${app}"
  xcrun stapler validate "${app}"
  spctl --assess --type execute --verbose "${app}"
  suffix="notarized"
fi
archive="${release_dir}/RepoDesk-${version}-macos-${build_arch}-${suffix}.zip"
ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
(cd "${release_dir}" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
echo "Prepared ${archive}"
