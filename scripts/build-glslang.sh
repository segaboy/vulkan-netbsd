#!/bin/sh
#
# build-glslang.sh — Build and install glslang from source on NetBSD.
#
# Scope:  Run AFTER setup-env.sh has prepared the environment. Builds the
#         Khronos glslang reference compiler, which provides glslangValidator
#         (required by Mesa's Vulkan build) and is NOT available in pkgsrc.
#
# Run as root, with a working network connection.
#
# This script mirrors docs/02-source-dependencies.md (glslang section).
#
# Usage:
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-glslang.sh
#     sh build-glslang.sh            # build + install glslang
#     sh build-glslang.sh --clean    # force a fresh build from scratch
#
# If a build is interrupted or the machine crashes, just run the same command
# again: the script detects the existing configured build and RESUMES it
# automatically. Use --clean to override this and rebuild from scratch.
#
# All output is also written to /root/vulkan-netbsd-glslang.log
#

set -e   # stop on the first error

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
GLSLANG_REPO="https://github.com/KhronosGroup/glslang.git"
LOG="/root/vulkan-netbsd-glslang.log"

FORCE_CLEAN=0
for _arg in "$@"; do
    case "$_arg" in
        --clean) FORCE_CLEAN=1 ;;
    esac
done

# --- Persistent logging -----------------------------------------------------
# Capture everything this script prints to a log file (in addition to the
# terminal), so a run can be inspected afterward or after an SSH drop:
#     tail -f /root/vulkan-netbsd-glslang.log
# Re-exec once through tee; the VNB_LOGGING guard prevents an infinite loop.
if [ -z "${VNB_LOGGING:-}" ]; then
    VNB_LOGGING=1
    export VNB_LOGGING
    {
        echo "############################################################"
        echo "# build-glslang.sh run: $(date)"
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

# Make sure the environment from setup-env.sh is active.
if [ -f /root/.profile ]; then
    . /root/.profile
fi

# cmake is required (installed by setup-env.sh).
if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found. Run setup-env.sh first." >&2
    exit 1
fi

# git is required (installed by setup-env.sh).
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not found. Run setup-env.sh first." >&2
    exit 1
fi

# --- Prebuilt fast path -----------------------------------------------------
# If a prebuilt glslang artifact matching this machine's environment exists on
# the configured GitHub Release, download and install it instead of building
# from source. Falls back to the source build on any mismatch or failure.
# Set ARTIFACT_TAG to choose the release; set NO_PREBUILT=1 to force a source
# build (useful when refining the build itself).

ART_LIB="$(dirname "$0")/lib-artifacts.sh"
if [ ! -f "$ART_LIB" ]; then
    # Script was likely fetched standalone via ftp; fetch the lib beside it.
    ftp -o "$ART_LIB" \
      "https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/lib-artifacts.sh" \
      >/dev/null 2>&1 || true
fi

if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
    . "$ART_LIB"
    say "Checking for a prebuilt glslang artifact"
    if try_fetch_artifact glslang; then
        if command -v glslangValidator >/dev/null 2>&1; then
            say "Installed prebuilt glslang - skipping source build"
            glslangValidator --version
            exit 0
        fi
        echo "Prebuilt installed but glslangValidator not on PATH; building from source."
    fi
fi

# --- Resume detection -------------------------------------------------------
# If a previously configured CMake build directory exists (has CMakeCache.txt),
# RESUME from it instead of re-cloning/reconfiguring - cmake --build only
# rebuilds what changed, so this recovers automatically from an interrupted or
# crashed build without the user needing to know how. --clean forces a fresh
# build. A partial dir (exists but no CMakeCache.txt) is treated as broken and
# rebuilt clean.

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/glslang/build/CMakeCache.txt" ]; then
    RESUME=1
fi

# --- Step 1: Clone glslang (or reuse existing source when resuming) ----------

if [ "$RESUME" -eq 1 ]; then
    say "Existing configured build found - RESUMING"
    echo "A previously configured glslang build directory was found."
    echo "Resuming from where it left off (normal after an interrupted or"
    echo "crashed build). The existing source is used as-is; it is not updated."
    echo ""
    echo "If the build later fails in a way that makes no sense, start fresh:"
    echo "    sh build-glslang.sh --clean"
    cd "$SRCDIR/glslang"
else
    say "Cloning glslang"
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d glslang ]; then
        git clone "$GLSLANG_REPO"
    else
        echo "glslang source already present, pulling latest."
        cd glslang && git pull && cd ..
    fi
    cd "$SRCDIR/glslang"
fi

# --- Step 2: Configure (skipped when resuming) ------------------------------

if [ "$RESUME" -eq 1 ]; then
    say "Skipping configure (already configured; resuming build)"
else
    say "Configuring glslang (CMake)"

    # If a stale/broken build dir exists (no cache), remove it for a clean start.
    if [ -d build ] && [ ! -f build/CMakeCache.txt ]; then
        rm -rf build
    fi
    # --clean forces a full wipe.
    if [ "$FORCE_CLEAN" -eq 1 ]; then
        rm -rf build
    fi

    # -DENABLE_OPT=OFF        skip the optional SPIRV-Tools optimizer dependency
    #                         (would otherwise be fetched by update_glslang_sources.py)
    # -DENABLE_GLSLANG_BINARIES=ON  build the standalone glslangValidator binary
    # -DGLSLANG_TESTS=OFF     skip the test suite
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_OPT=OFF \
      -DENABLE_GLSLANG_BINARIES=ON \
      -DGLSLANG_TESTS=OFF
fi

# --- Step 3: Build ----------------------------------------------------------

say "Building glslang"
cmake --build build -j"$(sysctl -n hw.ncpu)"

# --- Step 4: Install --------------------------------------------------------

say "Installing glslang to $PREFIX"
cmake --install build

# --- Step 5: Verify ---------------------------------------------------------

say "Verifying glslangValidator"
if command -v glslangValidator >/dev/null 2>&1; then
    glslangValidator --version
    echo ""
    echo "glslangValidator installed at: $(which glslangValidator)"
else
    echo "ERROR: glslangValidator not found on PATH after install." >&2
    echo "Check that $PREFIX/bin is in your PATH." >&2
    exit 1
fi

say "glslang build complete"
cat << 'EOF'
glslang is built and installed. glslangValidator is on your PATH.

Next step: build Mesa with the Vulkan (Lavapipe) driver.
(See docs — Mesa build guide, forthcoming.)
EOF
