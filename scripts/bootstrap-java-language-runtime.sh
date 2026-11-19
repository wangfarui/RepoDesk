#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
runtime_dir="${project_dir}/build/JavaLanguageRuntime"
download_dir="${project_dir}/build/JavaLanguageDownloads"

# Xcode and local verification may bootstrap the same runtime concurrently.
lock_dir="${project_dir}/build/.java-language-runtime-lock"
mkdir -p "${project_dir}/build"
attempt=0
until mkdir "${lock_dir}" 2>/dev/null; do
  (( attempt += 1 ))
  if (( attempt >= 600 )); then
    echo "Timed out waiting for Java runtime preparation; check ${lock_dir}" >&2
    exit 1
  fi
  sleep 1
done
temporary_dir=""
trap '[[ -z "${temporary_dir}" ]] || rm -rf "${temporary_dir}"; rmdir "${lock_dir}" 2>/dev/null || true' EXIT

jdt_version="1.61.0-202609031315"
jdt_archive="jdt-language-server-${jdt_version}.tar.gz"
jdt_url="https://download.eclipse.org/jdtls/milestones/1.61.0/${jdt_archive}"
jdt_sha256="338e7e73d61836651ba2453919a0d34fa763eb4e7c03342092309bffb8934c64"
jdt_license_url="https://raw.githubusercontent.com/eclipse-jdtls/eclipse.jdt.ls/126afcd347c5d69dc06718eb176cd0f3d2a5e698/LICENSE"
jdt_license_sha256="209fe24bf55677bbf81c2b0481c1403201fab57b3b4c609971eba4ec8162b99c"

temurin_version="21.0.8_9"
temurin_tag="jdk-21.0.8%2B9"
architecture="${REPODESK_BUILD_ARCH:-$(uname -m)}"
case "${architecture}" in
  arm64)
    temurin_arch="aarch64"
    temurin_sha256="7849fd9e0d48c6638a1f82a81000ef170e32600fd7a32fc257668e7e7ae041b4"
    ;;
  x86_64)
    temurin_arch="x64"
    temurin_sha256="34464861ed170ea0e5acdf870011f9e92f836e712b620ba37c4b2d0e5aeb8675"
    ;;
  *)
    echo "Unsupported macOS architecture: ${architecture}" >&2
    exit 1
    ;;
esac

temurin_archive="OpenJDK21U-jre_${temurin_arch}_mac_hotspot_${temurin_version}.tar.gz"
temurin_url="https://github.com/adoptium/temurin21-binaries/releases/download/${temurin_tag}/${temurin_archive}"
runtime_marker="jdtls=${jdt_version};temurin=${temurin_version};arch=${architecture}"

if [[ -f "${runtime_dir}/.repodesk-runtime-version" ]] \
  && [[ "$(<"${runtime_dir}/.repodesk-runtime-version")" == "${runtime_marker}" ]] \
  && [[ -x "${runtime_dir}/jre/Contents/Home/bin/java" || -x "${runtime_dir}/jre/bin/java" ]] \
  && [[ -d "${runtime_dir}/jdtls/config_mac" ]] \
  && [[ -f "${runtime_dir}/jdtls/LICENSE" ]] \
  && [[ -n "$(find "${runtime_dir}/jdtls/plugins" -maxdepth 1 -name 'org.eclipse.equinox.launcher_*.jar' -print -quit 2>/dev/null)" ]]; then
  echo "Java language runtime is current"
  exit 0
fi

mkdir -p "${download_dir}"

download_and_verify() {
  local url="$1"
  local destination="$2"
  local expected_sha256="$3"
  if [[ ! -f "${destination}" ]] \
    || [[ "$(shasum -a 256 "${destination}" | awk '{print $1}')" != "${expected_sha256}" ]]; then
    rm -f "${destination}"
    echo "Downloading ${destination:t}"
    curl --fail --location --retry 3 --output "${destination}.partial" "${url}"
    mv "${destination}.partial" "${destination}"
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "${destination}" | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "SHA-256 mismatch for ${destination:t}" >&2
    exit 1
  fi
}

jdt_path="${download_dir}/${jdt_archive}"
jdt_license_path="${download_dir}/eclipse-jdt-ls-LICENSE"
temurin_path="${download_dir}/${temurin_archive}"
download_and_verify "${jdt_url}" "${jdt_path}" "${jdt_sha256}"
download_and_verify "${jdt_license_url}" "${jdt_license_path}" "${jdt_license_sha256}"
download_and_verify "${temurin_url}" "${temurin_path}" "${temurin_sha256}"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/repodesk-java-runtime.XXXXXX")"
mkdir -p "${temporary_dir}/runtime/jdtls" "${temporary_dir}/runtime/jre"
tar -xzf "${jdt_path}" -C "${temporary_dir}/runtime/jdtls"
cp "${jdt_license_path}" "${temporary_dir}/runtime/jdtls/LICENSE"
tar -xzf "${temurin_path}" -C "${temporary_dir}/runtime/jre" --strip-components=1
print -r -- "${runtime_marker}" > "${temporary_dir}/runtime/.repodesk-runtime-version"

rm -rf "${runtime_dir}"
mv "${temporary_dir}/runtime" "${runtime_dir}"
echo "Prepared Java language runtime at ${runtime_dir}"
