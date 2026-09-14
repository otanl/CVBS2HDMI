#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
tools_dir="${project_root}/.tools"
install_dir="${tools_dir}/oss-cad-suite"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: this setup script is for macOS" >&2
    exit 1
fi

case "$(uname -m)" in
    arm64) asset_pattern='oss-cad-suite-darwin-arm64-.*\.tgz$' ;;
    x86_64) asset_pattern='oss-cad-suite-darwin-x64-.*\.tgz$' ;;
    *) echo "error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [[ -x "${install_dir}/bin/yosys" ]]; then
    echo "OSS CAD Suite is already installed at ${install_dir}"
    "${project_root}/scripts/tool" yosys -V
    exit 0
fi

mkdir -p "${tools_dir}"
release_json="$(mktemp "${TMPDIR:-/tmp}/oss-cad-release.XXXXXX")"
archive="$(mktemp "${TMPDIR:-/tmp}/oss-cad-suite.XXXXXX.tgz")"
cleanup() { rm -f "${release_json}" "${archive}"; }
trap cleanup EXIT

echo "Finding the latest OSS CAD Suite release..."
curl -fsSL \
    'https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest' \
    -o "${release_json}"

download_url="$(python3 - "${release_json}" "${asset_pattern}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as release_file:
    release = json.load(release_file)
pattern = re.compile(sys.argv[2])
for asset in release.get("assets", []):
    if pattern.search(asset["name"]):
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit("matching macOS archive was not found in the latest release")
PY
)"

echo "Downloading ${download_url##*/}..."
curl -fL --retry 3 "${download_url}" -o "${archive}"

echo "Installing into ${install_dir}..."
tar -xzf "${archive}" -C "${tools_dir}"
xattr -dr com.apple.quarantine "${install_dir}" 2>/dev/null || true

"${project_root}/scripts/tool" yosys -V
"${project_root}/scripts/tool" nextpnr-himbaechel --version
"${project_root}/scripts/tool" openFPGALoader --version
echo "Setup complete. Run: make sim && make build"

