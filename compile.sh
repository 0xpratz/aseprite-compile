#!/bin/bash
set -e  # Exit on any error

# CI-friendly version - no interactive prompts, uses BUILD_DIR env var

# Use BUILD_DIR if set (for CI), otherwise default to ~/output
if [[ -z "${BUILD_DIR}" ]]; then
    BUILD_DIR="${HOME}/output"
fi

INSTALL_DIR="${BUILD_DIR}/aseprite"
BINARY_DIR="${BUILD_DIR}/bin"
LAUNCHER_DIR="${BUILD_DIR}/applications"

SIGNATURE_FILE="${INSTALL_DIR}/compile-aseprite-linux"
BINARY_FILE="${BINARY_DIR}/aseprite"
LAUNCHER_FILE="${LAUNCHER_DIR}/aseprite.desktop"
ICON_FILE="${INSTALL_DIR}/data/icons/ase256.png"

echo "Building Aseprite to: ${BUILD_DIR}"

# In CI mode, always clean and rebuild
if [[ -n "${CI}" ]] || [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "CI environment detected - cleaning any existing installation"
    rm -rf "${INSTALL_DIR}" "${BINARY_DIR}" "${LAUNCHER_DIR}"
else
    # Interactive mode for local builds
    if [[ -f "${SIGNATURE_FILE}" ]] ; then
        read -e -p "Aseprite already installed. Update? (y/N): " choice
        [[ "${choice}" == [Yy]* ]] || exit 0
    else
        [[ -d "${INSTALL_DIR}" ]] \
            && { echo "Aseprite already installed to '${INSTALL_DIR}'. Aborting" >&2 ; exit 1 ; }
        { [[ -f "${LAUNCHER_FILE}" ]] || [[ -f "${BINARY_FILE}" ]] ; } \
            && { echo "Other aseprite data already installed to output directory. Aborting" >&2 ; exit 1 ; }
    fi
fi

# Create or use temp directory
if [[ -z "${TESTING}" ]] && [[ -z "${CI}" ]] && [[ -z "${GITHUB_ACTIONS}" ]] ; then
    WORK_DIR=$(mktemp -d -t 'compile-aseprite-linux-XXXXX') \
        || { echo "Unable to create temp folder" >&2 ; exit 1 ; }
else
    WORK_DIR="${BUILD_DIR}/temp-build"
    mkdir -p "${WORK_DIR}"
fi
WORK_DIR="$(realpath "${WORK_DIR}")"

echo "Working directory: ${WORK_DIR}"

cleanup() {
    code=$?
    echo "Cleaning up."
    if [[ -z "${TESTING}" ]] && [[ -z "${CI}" ]] && [[ -z "${GITHUB_ACTIONS}" ]] ; then
        echo "Removing temporary work directory: ${WORK_DIR}"
        rm -rf "${WORK_DIR}"
    else
        echo "Keeping work directory for CI: ${WORK_DIR}"
    fi
    exit "${code}"
}

trap "cleanup" EXIT

pushd "${WORK_DIR}"

# Download latest version of aseprite
echo "Fetching latest Aseprite release info..."
SOURCE_CODE=$(curl -s "https://api.github.com/repos/aseprite/aseprite/releases/latest" | awk '/browser_download_url/ {print $2}' | tr -d \")

if [[ -z "${SOURCE_CODE}" ]]; then
    echo "Failed to fetch release URL" >&2
    exit 1
fi

echo "Downloading Aseprite source code..."
wget -q --show-progress $SOURCE_CODE \
    || { echo "Unable to download the latest version of Aseprite." >&2 ; exit 1 ; }
echo "Aseprite downloaded from: ${SOURCE_CODE}"

# FILE is a filename like Aseprite-vX.X.X.X-Source.zip
FILE=$(echo $SOURCE_CODE | awk -F/ '{print $NF}')

# Unzip the source code
echo "Extracting source code..."
unzip -q $FILE -d aseprite \
    || { echo "Unable to decompress the source code, make sure you have the unzip package installed." >&2 ; exit 1 ; }
echo "${FILE} extracted."

# Only check for dependencies if not in CI (CI installs them separately)
if [[ -z "${CI}" ]] && [[ -z "${GITHUB_ACTIONS}" ]]; then
    echo "Checking distribution and installing dependencies..."
    
    # Check distro
    os_name=$(grep 'NAME=' /etc/os-release | head -n 1 | sed 's/NAME=//' | tr -d '"')

    # Assign package manager to a variable
    if [[ "$os_name" == *"Fedora"* ]]; then
        package_man="dnf"
    elif [[ $os_name == *"Debian"* ]] || [[ $os_name == *"Ubuntu"* ]] || [[ $os_name == *"Mint"* ]]; then
        package_man="apt"
    elif [[ $os_name == *"Arch"* ]] || [[ $os_name == *"Manjaro"* ]]; then
        package_man="pacman"
    else
        echo "Unsupported distro! If your distro supports APT, DNF or PACMAN, please manually modify the script."
        echo "Stopped installation!"
        exit 1
    fi

    echo "Enter sudo password to install dependencies. This is also a good time to plug in your computer, since compiling will take a long time."

    # Install dependencies
    if [[ $package_man == "dnf" ]]; then
        cat aseprite/INSTALL.md | grep -m1 "sudo dnf install" | bash 
    elif [[ $package_man == "apt" ]]; then
        cat aseprite/INSTALL.md | grep -m1 "sudo apt-get install" | bash
    elif [[ $package_man == "pacman" ]]; then
        deps=$(cat aseprite/INSTALL.md | grep -m1 "sudo pacman -S")
        deps=${deps/-S/-S --needed --noconfirm} 
        bash -c "$deps"
    fi

    [[ $? == 0 ]] \
        || { echo "Failed to install dependencies." >&2 ; exit 1 ; }
else
    echo "CI environment - skipping dependency installation (handled by workflow)"
fi

pushd aseprite

# Compile Aseprite with the provided build.sh script in the source code
echo "Starting Aseprite compilation (this may take a while)..."
./build.sh --auto --norun \
    || { echo "Compilation failed." >&2 ; exit 1 ; }

popd

# Prepare installation directories
echo "Installing compiled files..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}" "${BINARY_DIR}" "${LAUNCHER_DIR}" \
    || { echo "Unable to create install folder." >&2 ; exit 1 ; }

# Move compiled files and create symlinks
{ mv aseprite/build/bin/* "${INSTALL_DIR}" \
    && touch "${SIGNATURE_FILE}" \
    && ln -sf "${INSTALL_DIR}/aseprite" "${BINARY_FILE}" \
    && cp -f "${WORK_DIR}/aseprite/src/desktop/linux/aseprite.desktop" "${LAUNCHER_FILE}" \
; } || { echo "Failed to complete install." >&2 ; exit 1 ; }

# Replace the values on the .desktop file to the correct ones
sed -i "s|$(grep -m1 TryExec= "${LAUNCHER_FILE}")|TryExec=$BINARY_FILE|g" "${LAUNCHER_FILE}"
sed -i "s|$(grep -m1 Exec= "${LAUNCHER_FILE}")|Exec=$BINARY_FILE %U|g" "${LAUNCHER_FILE}"
sed -i "s|$(grep -m1 Icon= "${LAUNCHER_FILE}")|Icon=$ICON_FILE|g" "${LAUNCHER_FILE}"

echo ""
echo "✓ Done compiling!"
echo "All files are stored in '${BUILD_DIR}':"
echo "  - Aseprite installation: ${INSTALL_DIR}"
echo "  - Binary symlink: ${BINARY_FILE}"
echo "  - Desktop launcher: ${LAUNCHER_FILE}"
echo "  - Icon: ${ICON_FILE}"
echo ""
echo "Have fun!"
