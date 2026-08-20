#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/build/RepoDesk.app"
contents_dir="${app_dir}/Contents"

mkdir -p "${contents_dir}/MacOS" "${contents_dir}/Resources"
mkdir -p "${project_dir}/build/ModuleCache"

swift "${project_dir}/scripts/generate-app-icon.swift" \
  "${project_dir}/Support/Resources/RepoDeskIcon-1024.png" \
  "${project_dir}/Support/Resources/RepoDesk.icns"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${project_dir}/build/ModuleCache" \
  "${project_dir}"/RepoDeskApp/**/*.swift \
  -o "${contents_dir}/MacOS/RepoDesk"

cp "${project_dir}/Support/Info.plist" "${contents_dir}/Info.plist"
cp "${project_dir}/Support/Resources/RepoDesk.icns" "${contents_dir}/Resources/RepoDesk.icns"
codesign --force --deep --sign - "${app_dir}"
touch "${contents_dir}" "${app_dir}"

echo "Built ${app_dir}"
