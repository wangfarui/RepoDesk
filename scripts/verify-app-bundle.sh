#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
app_dir="${1:-${script_dir:h}/build/RepoDesk.app}"
contents="${app_dir}/Contents"
binary="${contents}/MacOS/RepoDesk"
expected_arch="${REPODESK_BUILD_ARCH:-$(uname -m)}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${contents}/Info.plist")" == "14.0" ]]
[[ "$(lipo -archs "${binary}")" == "${expected_arch}" ]]
otool -l "${binary}" | awk '/cmd LC_BUILD_VERSION/{found=1} found && /minos/{if ($2 == "14.0") valid=1; found=0} END{if (!valid) exit 1}'
[[ -s "${contents}/Resources/MergeFonts/JetBrainsMono-Regular.ttf" ]]
[[ -s "${contents}/Resources/MergeFonts/OFL.txt" ]]
[[ -s "${contents}/Resources/ThirdParty/NOTICES.md" ]]
[[ -s "${contents}/Resources/LICENSE" ]]
[[ -s "${contents}/Resources/JavaLanguage/jdtls/LICENSE" ]]
[[ -s "${contents}/Resources/JarDecompiler/LICENSE.txt" ]]
java_path="${contents}/Resources/JavaLanguage/jre/Contents/Home/bin/java"
[[ -x "${java_path}" ]]
[[ "$(lipo -archs "${java_path}")" == "${expected_arch}" ]]
codesign --verify --deep --strict "${app_dir}"
echo "App bundle verified: macOS 14.0+, ${expected_arch}, bundled runtime and notices"
