#!/bin/sh
#
# build-glslang.sh - Build and install glslang from source on NetBSD.
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

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
GLSLANG_REPO="https://github.com/KhronosGroup/glslang.git"
LOG="/root/vulkan-netbsd-glslang.log"
RAW_BASE="https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts"

FORCE_CLEAN=0
for _arg in "$@"; do
    case "$_arg" in
        --clean) FORCE_CLEAN=1 ;;
    esac
done

# --- Load shared progress UI (with graceful fallback) -----------------------
# lib-ui.sh gives the phased progress bar / spinner / summary shared with the
# other scripts. If it can't be loaded (e.g. offline), fall back to plain output
# so the build still runs.

SCRIPT_DIR="$(dirname "$0")"
UI_LIB="$SCRIPT_DIR/lib-ui.sh"
if [ ! -f "$UI_LIB" ]; then
    ftp -o "$UI_LIB" "$RAW_BASE/lib-ui.sh" >/dev/null 2>&1 || true
fi

# Start the log fresh with a run header.
{
    echo "############################################################"
    echo "# build-glslang.sh run: $(date)   args: $*"
    echo "############################################################"
} >> "$LOG"

if [ -f "$UI_LIB" ]; then
    . "$UI_LIB"
    UI=1
else
    UI=0
    # Minimal fallbacks so the rest of the script is UI-agnostic.
    ui_log()     { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
    ui_phase()   { echo ""; echo "=====> $1"; ( "$2" ) 2>&1 | tee -a "$LOG"; }
    ui_build()   { echo ""; echo "=====> $1"; ( "$2" ) 2>&1 | tee -a "$LOG"; }
    ui_step_ok() { echo "  ok  $1"; }
    ui_summary() { :; }
fi

STEP=0
TOTAL=5
RESULTS=""
RUN_START="$(date +%s)"

# --- Pre-flight checks ------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Make sure the environment from setup-env.sh is active.
if [ -f /root/.profile ]; then
    . /root/.profile
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found. Run setup-env.sh first." >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not found. Run setup-env.sh first." >&2
    exit 1
fi

# --- Prebuilt fast path -----------------------------------------------------
# If a prebuilt glslang artifact matching this machine's environment exists on
# the configured GitHub Release, download and install it instead of building
# from source. Set ARTIFACT_TAG to choose the release; NO_PREBUILT=1 forces a
# source build.

ART_LIB="$SCRIPT_DIR/lib-artifacts.sh"
if [ ! -f "$ART_LIB" ]; then
    ftp -o "$ART_LIB" "$RAW_BASE/lib-artifacts.sh" >/dev/null 2>&1 || true
fi

if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
    . "$ART_LIB"
    echo ""
    echo "=====> Checking for a prebuilt glslang artifact"
    if try_fetch_artifact glslang; then
        if command -v glslangValidator >/dev/null 2>&1; then
            echo "Installed prebuilt glslang - skipping source build."
            glslangValidator --version
            exit 0
        fi
        echo "Prebuilt installed but glslangValidator not on PATH; building from source."
    fi
fi

# --- Resume detection -------------------------------------------------------
# If a previously configured CMake build directory exists (has CMakeCache.txt),
# RESUME from it. --clean forces a fresh build; a partial dir (no cache) is
# treated as broken and rebuilt clean.

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/glslang/build/CMakeCache.txt" ]; then
    RESUME=1
fi

# --- Phase functions --------------------------------------------------------

phase_clone() {
    if [ "$RESUME" -eq 1 ]; then
        echo "Existing configured build found - resuming; using existing source."
        cd "$SRCDIR/glslang"
        return 0
    fi
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d glslang ]; then
        git clone "$GLSLANG_REPO"
    else
        echo "glslang source already present, pulling latest."
        cd glslang && git pull && cd ..
    fi
    cd "$SRCDIR/glslang"
}

phase_configure() {
    cd "$SRCDIR/glslang"
    if [ "$RESUME" -eq 1 ]; then
        echo "Already configured; skipping configure (resuming)."
        return 0
    fi
    # Remove a stale/broken build dir, or wipe on --clean.
    if [ -d build ] && [ ! -f build/CMakeCache.txt ]; then rm -rf build; fi
    if [ "$FORCE_CLEAN" -eq 1 ]; then rm -rf build; fi

    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_OPT=OFF \
      -DENABLE_GLSLANG_BINARIES=ON \
      -DGLSLANG_TESTS=OFF
}

phase_compile() {
    cd "$SRCDIR/glslang"
    cmake --build build -j"$(sysctl -n hw.ncpu)"
}

phase_install() {
    cd "$SRCDIR/glslang"
    cmake --install build
}

phase_verify() {
    if command -v glslangValidator >/dev/null 2>&1; then
        glslangValidator --version
        echo ""
        echo "glslangValidator installed at: $(which glslangValidator)"
    else
        echo "ERROR: glslangValidator not found on PATH after install." >&2
        echo "Check that $PREFIX/bin is in your PATH." >&2
        return 1
    fi
}

# --- Run --------------------------------------------------------------------

if [ "$UI" -eq 1 ]; then
    printf '%s== vulkan-netbsd: build glslang ==%s\n' "$UI_BAR" "$UI_RESET"
    printf 'Logging all output to: %s\n' "$LOG"
fi

ui_phase "Cloning glslang"        phase_clone     || { ui_summary; exit 1; }
ui_phase "Configuring (CMake)"    phase_configure || { ui_summary; exit 1; }
ui_build "Building glslang"       phase_compile   || { ui_summary; exit 1; }
ui_phase "Installing to $PREFIX"  phase_install   || { ui_summary; exit 1; }
ui_phase "Verifying"              phase_verify    || { ui_summary; exit 1; }

ui_summary

echo ""
printf '%sglslang build complete.%s\n' "${UI_OK:-}" "${UI_RESET:-}"
cat << EOF

glslang is built and installed. glslangValidator is on your PATH.

Next step: build Mesa with the Vulkan (Lavapipe) driver:
    sh build-mesa.sh --build

Full log of this run: $LOG
EOF
