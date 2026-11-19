#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/build/RepoDesk.app"
mkdir -p "${project_dir}/build"
staging_dir="$(mktemp -d "${project_dir}/build/.repodesk-app.XXXXXX")"
staged_app="${staging_dir}/RepoDesk.app"
contents_dir="${staged_app}/Contents"
trap 'rm -rf "${staging_dir}"' EXIT
build_arch="${REPODESK_BUILD_ARCH:-$(uname -m)}"
deployment_target="14.0"

# Swift macro plugins otherwise try to nest sandbox-exec inside constrained agent sessions.
swiftc() {
  command swiftc -disable-sandbox "$@"
}

"${script_dir}/bootstrap-java-language-runtime.sh"
"${script_dir}/bootstrap-jar-decompiler.sh"

mkdir -p "${contents_dir}/MacOS" "${contents_dir}/Resources"
mkdir -p "${project_dir}/build/ModuleCache"

swift -module-cache-path "${project_dir}/build/ModuleCache" \
  "${project_dir}/scripts/generate-app-icon.swift" \
  "${project_dir}/Support/Resources/RepoDeskIcon-1024.png" \
  "${project_dir}/Support/Resources/RepoDesk.icns"

swiftc \
  -target "${build_arch}-apple-macos${deployment_target}" \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${project_dir}/build/ModuleCache" \
  "${project_dir}"/RepoDeskApp/**/*.swift \
  -o "${contents_dir}/MacOS/RepoDesk"

cp "${project_dir}/Support/Info.plist" "${contents_dir}/Info.plist"
cp "${project_dir}/LICENSE" "${contents_dir}/Resources/LICENSE"
cp "${project_dir}/Support/Resources/RepoDesk.icns" "${contents_dir}/Resources/RepoDesk.icns"
ditto "${project_dir}/Support/Resources/MergeFonts" "${contents_dir}/Resources/MergeFonts"
ditto "${project_dir}/Support/ThirdParty" "${contents_dir}/Resources/ThirdParty"
rm -rf "${contents_dir}/Resources/JavaLanguage"
ditto "${project_dir}/build/JavaLanguageRuntime" "${contents_dir}/Resources/JavaLanguage"
rm -rf "${contents_dir}/Resources/JarDecompiler"
ditto "${project_dir}/build/JarDecompilerRuntime" "${contents_dir}/Resources/JarDecompiler"
codesign --force --deep --sign - "${staged_app}"
codesign --verify --deep --strict "${staged_app}"
touch "${contents_dir}" "${staged_app}"

# Only replace the runnable app after a complete, signed build. Keep local
# preferences outside the bundle and avoid carrying stale resources into releases.
if [[ -e "${app_dir}" ]]; then
  mv "${app_dir}" "${staging_dir}/Previous.app"
fi
if ! mv "${staged_app}" "${app_dir}"; then
  [[ ! -e "${staging_dir}/Previous.app" ]] || mv "${staging_dir}/Previous.app" "${app_dir}"
  exit 1
fi

echo "Built ${app_dir}"
