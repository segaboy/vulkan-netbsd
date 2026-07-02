#!/bin/sh
#
# install-mesa.sh — Install a built Mesa tree (the Lavapipe Vulkan driver) into
#                   the pkgsrc prefix and verify the ICD is registered.
#
# Scope:  Run AFTER build-mesa.sh --build has compiled Mesa. Installs the
#         Lavapipe driver (libvulkan_lvp.so) and its ICD manifest into
#         /usr/pkg, then verifies the install.
#
# This is separated from build-mesa.sh so the install step can be run (or
# re-run) on its own without touching the build.
#
# Run as root.
#
# Usage:
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/install-mesa.sh
#     sh install-mesa.sh
#
# All output is also written to /root/vulkan-netbsd-install.log
#

set -e

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
BUILD_DIR="build"
MESA_DIR="$SRCDIR/mesa"
LOG="/root/vulkan-netbsd-install.log"

LVP_SO="$MESA_DIR/$BUILD_DIR/src/gallium/targets/lavapipe/libvulkan_lvp.so"

# --- Persistent logging -----------------------------------------------------
if [ -z "${VNB_LOGGING:-}" ]; then
    VNB_LOGGING=1
    export VNB_LOGGING
    {
        echo "############################################################"
        echo "# install-mesa.sh run: $(date)"
        echo "############################################################"
    } >> "$LOG"
    exec sh "$0" "$@" 2>&1 | tee -a "$LOG"
fi

# --- Helpers ----------------------------------------------------------------

say() {
    echo ""
    echo "=====> $1"
    echo ""
}

# --- Pre-flight checks ------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [ -f /root/.profile ]; then
    . /root/.profile
fi

if [ ! -d "$MESA_DIR/$BUILD_DIR" ]; then
    echo "ERROR: no Mesa build directory at $MESA_DIR/$BUILD_DIR." >&2
    echo "Run build-mesa.sh --build first." >&2
    exit 1
fi

if [ ! -f "$LVP_SO" ]; then
    echo "ERROR: the Lavapipe driver has not been built:" >&2
    echo "    $LVP_SO" >&2
    echo "Run build-mesa.sh --build first (or resume it)." >&2
    exit 1
fi

# --- Install ----------------------------------------------------------------

say "Installing Mesa (Lavapipe) into $PREFIX"
cd "$MESA_DIR"
ninja -C "$BUILD_DIR" install

# --- Verify -----------------------------------------------------------------

say "Verifying installation"

INSTALLED_SO="$PREFIX/lib/libvulkan_lvp.so"
ICD_DIR="$PREFIX/share/vulkan/icd.d"

_ok=1

if [ -f "$INSTALLED_SO" ]; then
    echo "Driver installed: $INSTALLED_SO"
    ls -la "$INSTALLED_SO"
else
    echo "ERROR: driver not found at $INSTALLED_SO" >&2
    _ok=0
fi

echo ""
if [ -d "$ICD_DIR" ] && [ -n "$(ls -A "$ICD_DIR" 2>/dev/null)" ]; then
    echo "ICD manifest(s) in $ICD_DIR:"
    ls -la "$ICD_DIR"
    echo ""
    for j in "$ICD_DIR"/*.json; do
        [ -f "$j" ] || continue
        echo "--- $j ---"
        cat "$j"
        echo ""
    done
else
    echo "ERROR: no ICD manifest found in $ICD_DIR" >&2
    echo "The Vulkan loader would not be able to discover the driver." >&2
    _ok=0
fi

echo ""
echo "Shared-library dependencies of the installed driver:"
ldd "$INSTALLED_SO" 2>/dev/null || echo "(ldd failed)"

# --- Result -----------------------------------------------------------------

say "Done"
if [ "$_ok" -eq 1 ]; then
    cat << EOF
The Lavapipe Vulkan driver is installed and registered as an ICD.

  Driver:   $INSTALLED_SO
  Manifest: $ICD_DIR

NOTE: This installs the Vulkan *driver* (ICD). To actually run a Vulkan
program you also need the Vulkan *loader* (libvulkan.so.1), which apps link
against and which discovers this ICD via the manifest above. Building the
loader is a separate step.

Full log: $LOG
EOF
else
    echo "Installation completed with problems - see the errors above and $LOG." >&2
    exit 1
fi
