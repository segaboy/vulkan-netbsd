#!/bin/sh
#
# build-mesa.sh — Clone and configure Mesa with the Vulkan software driver
#                 (Lavapipe / swrast) on NetBSD.
#
# Scope:  Run AFTER setup-env.sh and build-glslang.sh. Clones Mesa, installs
#         the last few build tools it needs (bison, flex), and runs the Meson
#         configure targeting the Lavapipe software Vulkan driver.
#
# STATUS: This currently takes Mesa through a SUCCESSFUL MESON CONFIGURE.
#         The actual compile+install step (ninja) is provided but has NOT yet
#         been confirmed end-to-end on NetBSD. See docs.
#
# Run as root, with a working network connection.
#
# Usage:
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-mesa.sh
#     sh build-mesa.sh
#
#     # To also run the (unconfirmed) compile step:
#     sh build-mesa.sh --build
#

set -e

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build"

DO_BUILD=0
[ "$1" = "--build" ] && DO_BUILD=1

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

# Load the environment prepared by setup-env.sh.
if [ -f /root/.profile ]; then
    . /root/.profile
fi

for tool in git cmake meson ninja pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' not found. Run setup-env.sh first." >&2
        exit 1
    fi
done

if ! command -v glslangValidator >/dev/null 2>&1; then
    echo "ERROR: glslangValidator not found. Run build-glslang.sh first." >&2
    exit 1
fi

# Mesa's configure needs a healthy python3 with mako, yaml, and packaging.
# setup-env.sh verifies this, but re-check here so this script fails clearly
# if run against an environment that wasn't fully prepared.
if ! python3 -c "from packaging.version import Version; import mako, yaml" 2>/dev/null; then
    echo "ERROR: python3 is missing mako, yaml, or packaging." >&2
    echo "Run setup-env.sh (it installs these), or:" >&2
    echo "    pkg_add py312-mako py312-yaml py312-packaging" >&2
    exit 1
fi

# --- Step 1: Install remaining build tools (bison, flex) --------------------

say "Installing bison and flex (parser/lexer, required by Mesa configure)"
# Mesa accepts bison or byacc; it needs flex for the lexer. Install both.
pkg_add bison flex || echo "note: bison/flex may already be present"

# --- Step 2: Clone Mesa -----------------------------------------------------

say "Cloning Mesa"
mkdir -p "$SRCDIR"
cd "$SRCDIR"
if [ ! -d mesa ]; then
    git clone "$MESA_REPO"
else
    echo "Mesa source already present, pulling latest."
    cd mesa && git pull && cd ..
fi

# --- Step 3: Configure with Meson (Lavapipe / swrast) -----------------------

say "Configuring Mesa (Meson) - Vulkan swrast (Lavapipe), gallium llvmpipe"
cd "$SRCDIR/mesa"

# Wipe any previous build dir for a clean, reproducible configure.
rm -rf "$BUILD_DIR"

# Flag notes:
#   -Dvulkan-drivers=swrast     Lavapipe, the software Vulkan driver (the target)
#   -Dgallium-drivers=llvmpipe  LLVM-backed software rasterizer Lavapipe builds on
#   -Dplatforms=x11             window-system integration (X11 libs from xbase/xcomp)
#   -Dglx/-Degl/-Dgbm=disabled  turn off OpenGL-adjacent pieces we don't need,
#                               reducing the surface for platform-specific issues
# LLVM is auto-detected via llvm-config on PATH (no explicit flag needed).
meson setup "$BUILD_DIR" \
  --prefix="$PREFIX" \
  -Dbuildtype=release \
  -Dvulkan-drivers=swrast \
  -Dgallium-drivers=llvmpipe \
  -Dplatforms=x11 \
  -Dglx=disabled \
  -Degl=disabled \
  -Dgbm=disabled

say "Meson configure complete"
echo "Mesa configured successfully with the Vulkan swrast (Lavapipe) driver."

# --- Step 4: (Optional) build -----------------------------------------------

if [ "$DO_BUILD" -eq 1 ]; then
    say "Building Mesa (ninja) - NOTE: not yet confirmed end-to-end on NetBSD"
    ninja -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

    say "Installing Mesa to $PREFIX"
    ninja -C "$BUILD_DIR" install

    say "Mesa build + install step finished"
    echo "If this completed cleanly, verify the Vulkan ICD was installed:"
    echo "    ls $PREFIX/share/vulkan/icd.d/"
else
    cat << EOF

Configure-only run complete. To attempt the compile + install step (not yet
confirmed working end-to-end on NetBSD), re-run with:

    sh build-mesa.sh --build

Or run it manually from $SRCDIR/mesa:

    ninja -C $BUILD_DIR -j\$(sysctl -n hw.ncpu)
    ninja -C $BUILD_DIR install
EOF
fi
