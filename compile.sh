#!/usr/bin/env bash
set -euo pipefail

# Configurable:
OUTPUT_NAME="${OUTPUT_NAME:-build}"
BASE_DIR="${HOME:-/root}"
BUILD_DIR="${BUILD_DIR:-${BASE_DIR}/${OUTPUT_NAME}}"

# Tools we need
REQUIRED_CMDS=(curl wget mktemp rm unzip tar find sed awk chmod cp mkdir mv grep)

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    echo "Install it and retry." >&2
    exit 2
  fi
done

# Helpers
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "info: $*"; }

WORK_DIR="$(mktemp -d -t compile-aseprite-XXXXX)"
trap 'rc=$?; rm -rf "${WORK_DIR}" || true; exit ${rc}' EXIT

cd "${WORK_DIR}"

GITHUB_API="https://api.github.com/repos/aseprite/aseprite/releases/latest"
info "Fetching release metadata from GitHub..."
RELEASE_JSON="$(curl -sL "${GITHUB_API}")" || die "Failed to fetch release metadata."

# Prefer release asset ending with tar.gz or .zip, otherwise take first browser_download_url,
# otherwise fall back to zipball_url (source code) which is at top-level of release object.
SOURCE_URL=""
# try to get preferred asset (tar.gz or zip)
SOURCE_URL="$(printf '%s\n' "${RELEASE_JSON}" \
  | awk -F\" '/browser_download_url/ {print $4}' \
  | grep -E '\.tar\.gz$|\.tgz$|\.zip$|\.tar\.xz$' \
  | head -n1 || true )"

# if not found, try first browser_download_url
if [[ -z "${SOURCE_URL}" ]]; then
  SOURCE_URL="$(printf '%s\n' "${RELEASE_JSON}" | awk -F\" '/browser_download_url/ {print $4; exit}')"
fi

# if still not found, fall back to zipball_url / tarball_url
if [[ -z "${SOURCE_URL}" ]]; then
  SOURCE_URL="$(printf '%s\n' "${RELEASE_JSON}" | awk -F\" '/"zipball_url"/ {print $4; exit}')"
fi
if [[ -z "${SOURCE_URL}" ]]; then
  SOURCE_URL="$(printf '%s\n' "${RELEASE_JSON}" | awk -F\" '/"tarball_url"/ {print $4; exit}')"
fi

if [[ -z "${SOURCE_URL}" ]]; then
  die "Could not determine a release download URL from GitHub API."
fi

info "Determined source URL: ${SOURCE_URL}"

# Pick filename based on URL
FNAME="$(basename "${SOURCE_URL}" | sed 's/[^A-Za-z0-9._-]/_/g')"
# if URL is something like zipball or tarball without extension, name it release-archive
if [[ "${FNAME}" == "" || "${FNAME}" == "release" ]]; then
  FNAME="release-archive"
fi

DOWNLOAD_PATH="${WORK_DIR}/${FNAME}"

info "Downloading to ${DOWNLOAD_PATH}..."
# Use curl if it's a zipball/tarball (curl preserves headers), fallback to wget
if command -v curl >/dev/null 2>&1; then
  curl -L --fail -o "${DOWNLOAD_PATH}" "${SOURCE_URL}" || die "Download failed: ${SOURCE_URL}"
else
  wget -O "${DOWNLOAD_PATH}" "${SOURCE_URL}" || die "Download failed: ${SOURCE_URL}"
fi

# Try to detect archive type and extract accordingly
extract_dir="${WORK_DIR}/src"
mkdir -p "${extract_dir}"

case "${DOWNLOAD_PATH}" in
  *.zip)
    info "Extracting zip..."
    unzip -q "${DOWNLOAD_PATH}" -d "${extract_dir}" || die "Unzip failed."
    ;;
  *.tar.gz|*.tgz)
    info "Extracting tar.gz..."
    tar -xzf "${DOWNLOAD_PATH}" -C "${extract_dir}" || die "tar -xzf failed."
    ;;
  *.tar.xz)
    info "Extracting tar.xz..."
    tar -xJf "${DOWNLOAD_PATH}" -C "${extract_dir}" || die "tar -xJf failed."
    ;;
  *)
    # If file has no extension, attempt to extract as tar, then zip; if neither, treat as single file
    if tar -tf "${DOWNLOAD_PATH}" >/dev/null 2>&1; then
      info "Extracting (tar autodetect)..."
      tar -xf "${DOWNLOAD_PATH}" -C "${extract_dir}" || die "tar -xf failed."
    elif unzip -t "${DOWNLOAD_PATH}" >/dev/null 2>&1; then
      info "Extracting (zip autodetect)..."
      unzip -q "${DOWNLOAD_PATH}" -d "${extract_dir}" || die "Unzip failed."
    else
      info "Downloaded file is not an archive; saving as-is."
      mkdir -p "${extract_dir}/single-file"
      mv "${DOWNLOAD_PATH}" "${extract_dir}/single-file/$(basename "${DOWNLOAD_PATH}")"
    fi
    ;;
esac

# Find the directory containing build.sh (aseprite's upstream build script)
info "Locating source directory (searching for build.sh)..."
SOURCE_DIR="$(find "${extract_dir}" -type f -name build.sh -print -quit || true)"
if [[ -z "${SOURCE_DIR}" ]]; then
  die "Could not find build.sh in extracted archive. Aborting."
fi
SOURCE_DIR="$(dirname "${SOURCE_DIR}")"
info "Found build script in: ${SOURCE_DIR}"
cd "${SOURCE_DIR}"

# Ensure build.sh executable
chmod +x ./build.sh || true

# Run build. Upstream build.sh may require dependencies; we do a best-effort run.
info "Running build.sh --auto --norun (this may require external build deps)..."
if ! ./build.sh --auto --norun; then
  die "Upstream build script failed. Check the output above for missing dependencies."
fi

# Prepare BUILD_DIR
rm -rf -- "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/data/icons"

# Collect outputs. Look in common locations; fall back to searching for an executable named 'aseprite'
if [[ -d "build/bin" ]]; then
  info "Copying files from build/bin to ${BUILD_DIR}..."
  cp -a build/bin/* "${BUILD_DIR}/" || die "Failed to copy build/bin contents."
elif [[ -d "bin" ]]; then
  info "Copying files from bin to ${BUILD_DIR}..."
  cp -a bin/* "${BUILD_DIR}/" || die "Failed to copy bin contents."
else
  # try to find an executable named aseprite
  ASEPI="$(find . -type f -name 'aseprite' -perm /111 -print -quit || true)"
  if [[ -n "${ASEPI}" ]]; then
    info "Found aseprite executable at ${ASEPI}; copying to ${BUILD_DIR}/aseprite"
    cp -a "${ASEPI}" "${BUILD_DIR}/aseprite" || die "Failed to copy aseprite executable."
  else
    # try to find any likely binary under build/
    ANYBIN="$(find build -type f -perm /111 -print -quit || true)"
    if [[ -n "${ANYBIN}" ]]; then
      info "Copying found executable ${ANYBIN} to ${BUILD_DIR}/"
      cp -a "${ANYBIN}" "${BUILD_DIR}/" || die "Failed to copy discovered executable."
    else
      die "No build outputs found (checked build/bin, bin, and searched for executables)."
    fi
  fi
fi

# Copy .desktop and icons (best-effort)
if [[ -f "src/desktop/linux/aseprite.desktop" ]]; then
  cp -f "src/desktop/linux/aseprite.desktop" "${BUILD_DIR}/aseprite.desktop" || true
fi

# a few possible icon locations used upstream
if [[ -f "data/icons/ase256.png" ]]; then
  cp -f "data/icons/ase256.png" "${BUILD_DIR}/data/icons/ase256.png" || true
elif [[ -f "src/desktop/linux/ase256.png" ]]; then
  cp -f "src/desktop/linux/ase256.png" "${BUILD_DIR}/data/icons/ase256.png" || true
elif [[ -f "resources/icons/ase256.png" ]]; then
  cp -f "resources/icons/ase256.png" "${BUILD_DIR}/data/icons/ase256.png" || true
fi

# Signature marker
touch "${BUILD_DIR}/compile-aseprite-linux"

info "Build complete. Artifacts placed in: ${BUILD_DIR}"
