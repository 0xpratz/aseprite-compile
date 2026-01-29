#!/usr/bin/env bash
set -euo pipefail

# Where to place final artifacts (default ./build). Override with OUTPUT_NAME or absolute BUILD_DIR.
OUTPUT_NAME="${OUTPUT_NAME:-build}"
BASE_DIR="$(pwd)"
BUILD_DIR="${BUILD_DIR:-${BASE_DIR}/${OUTPUT_NAME}}"

# temp workdir
WORK_DIR="$(mktemp -d -t compile-aseprite-XXXXX)"
trap 'rc=$?; rm -rf "${WORK_DIR}"; exit ${rc}' EXIT

cd "${WORK_DIR}"

# Fetch latest release source URL from GitHub
SOURCE_URL="$(curl -s "https://api.github.com/repos/aseprite/aseprite/releases/latest" \
  | awk -F\" '/browser_download_url/ {print $4; exit}')"

if [[ -z "${SOURCE_URL}" ]]; then
  echo "Could not determine latest release URL." >&2
  exit 1
fi

wget -q -O release.zip "${SOURCE_URL}" || { echo "Download failed: ${SOURCE_URL}" >&2; exit 1; }
unzip -q release.zip -d aseprite || { echo "Unzip failed." >&2; exit 1; }

cd aseprite

# Build using upstream script. Ensure you have required deps installed before running this script.
./build.sh --auto --norun || { echo "Build failed." >&2; exit 1; }

# Collect outputs
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/data/icons"

if [[ -d "build/bin" ]]; then
  mv build/bin/* "${BUILD_DIR}/"
else
  echo "Expected build output 'build/bin' not found." >&2
  exit 1
fi

# Copy .desktop and icons if present (best-effort)
if [[ -f "src/desktop/linux/aseprite.desktop" ]]; then
  cp -f "src/desktop/linux/aseprite.desktop" "${BUILD_DIR}/aseprite.desktop"
fi
if [[ -f "data/icons/ase256.png" ]]; then
  cp -f "data/icons/ase256.png" "${BUILD_DIR}/data/icons/ase256.png"
elif [[ -f "src/desktop/linux/ase256.png" ]]; then
  cp -f "src/desktop/linux/ase256.png" "${BUILD_DIR}/data/icons/ase256.png"
fi

# Signature marker
touch "${BUILD_DIR}/compile-aseprite-linux"

echo "Build complete. Artifacts placed in: ${BUILD_DIR}"
