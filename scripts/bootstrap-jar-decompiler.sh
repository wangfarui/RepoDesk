#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
runtime_dir="${project_dir}/build/JarDecompilerRuntime"
download_dir="${project_dir}/build/JarDecompilerDownloads"

cfr_version="0.152"
cfr_archive="cfr-${cfr_version}.jar"
cfr_url="https://www.benf.org/other/cfr/${cfr_archive}"
cfr_sha256="f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2"
license_path="${project_dir}/Support/ThirdParty/CFR-LICENSE.txt"
license_sha256="d0b36fd265410a15e634220fdc6101976582799a09c69764f44bc21c21611527"

if [[ "$(shasum -a 256 "${license_path}" | awk '{print $1}')" != "${license_sha256}" ]]; then
  echo "SHA-256 mismatch for CFR license" >&2
  exit 1
fi

if [[ -f "${runtime_dir}/${cfr_archive}" ]] \
  && [[ "$(shasum -a 256 "${runtime_dir}/${cfr_archive}" | awk '{print $1}')" == "${cfr_sha256}" ]] \
  && cmp -s "${license_path}" "${runtime_dir}/LICENSE.txt" \
  && cmp -s "${project_dir}/Support/ThirdParty/CFR-NOTICE.md" "${runtime_dir}/NOTICE.md"; then
  echo "JAR decompiler runtime is current"
  exit 0
fi

mkdir -p "${download_dir}"
cfr_path="${download_dir}/${cfr_archive}"
temporary_dir="$(mktemp -d "${download_dir}/.prepare.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

if [[ ! -f "${cfr_path}" ]] \
  || [[ "$(shasum -a 256 "${cfr_path}" | awk '{print $1}')" != "${cfr_sha256}" ]]; then
  echo "Downloading ${cfr_archive}"
  curl --fail --location --retry 3 --output "${temporary_dir}/${cfr_archive}" "${cfr_url}"
  if [[ "$(shasum -a 256 "${temporary_dir}/${cfr_archive}" | awk '{print $1}')" != "${cfr_sha256}" ]]; then
    echo "SHA-256 mismatch for ${cfr_archive}" >&2
    exit 1
  fi
  mv "${temporary_dir}/${cfr_archive}" "${cfr_path}"
fi

mkdir -p "${temporary_dir}/runtime"
cp "${cfr_path}" "${temporary_dir}/runtime/${cfr_archive}"
cp "${license_path}" "${temporary_dir}/runtime/LICENSE.txt"
cp "${project_dir}/Support/ThirdParty/CFR-NOTICE.md" "${temporary_dir}/runtime/NOTICE.md"
rm -rf "${runtime_dir}"
mv "${temporary_dir}/runtime" "${runtime_dir}"
echo "Prepared JAR decompiler runtime at ${runtime_dir}"
