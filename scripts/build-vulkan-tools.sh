#!/bin/sh
#
# build-vulkan-tools.sh - Build and install vulkaninfo (Khronos Vulkan-Tools)
#                         on NetBSD, then run it against the installed stack.
#
# Scope:  Run AFTER setup-env.sh, the Mesa/Lavapipe driver install, and
#         build-loader.sh. Vulkan-Tools is not in the NetBSD binary package set,
#         so it is built from source. Only vulkaninfo is built (vkcube and the
#         mock ICD are disabled), so the only dependencies are the already-
#         installed Vulkan-Headers and Vulkan-Loader.
#
# This script does something the build scripts do not: after installing
# vulkaninfo, it RUNS it. That is the real end-to-end test - the loader must
# find the Lavapipe ICD via its manifest, load it, and enumerate it as a Vulkan
# device. Success here means Vulkan actually runs on NetBSD.
#
# Run as root, with a working network connection.
#
# Usage:
#     ftp -4 https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-vulkan-tools.sh
#     sh build-vulkan-tools.sh            # build + install vulkaninfo, then run it
#     sh build-vulkan-tools.sh --clean    # force a fresh build from scratch
#
# If a build is interrupted or the machine crashes, run the same command again:
# the script detects the existing configured build and RESUMES it. Use --clean
# to override and rebuild from scratch.
#
# All output is also written to /root/vulkan-netbsd-tools.log
#

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
TOOLS_REPO="https://github.com/KhronosGroup/Vulkan-Tools.git"
LOG="/root/vulkan-netbsd-tools.log"
RAW_BASE="https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts"

FORCE_CLEAN=0
for _arg in "$@"; do
    case "$_arg" in
        --clean) FORCE_CLEAN=1 ;;
    esac
done

# --- Load shared progress UI (with graceful fallback) -----------------------

SCRIPT_DIR="$(dirname "$0")"
UI_LIB="$SCRIPT_DIR/lib-ui.sh"
if [ ! -f "$UI_LIB" ]; then
    ftp -4 -o "$UI_LIB" "$RAW_BASE/lib-ui.sh" >/dev/null 2>&1 || true
fi

{
    echo "############################################################"
    echo "# build-vulkan-tools.sh run: $(date)   args: $*"
    echo "############################################################"
} >> "$LOG"

if [ -f "$UI_LIB" ]; then
    . "$UI_LIB"
    UI=1
else
    UI=0
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

if [ -f /root/.profile ]; then
    . /root/.profile
fi

for tool in git cmake python3 pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' not found. Run setup-env.sh first." >&2
        exit 1
    fi
done

# vulkaninfo needs the loader (libvulkan) and headers, both from earlier steps.
if [ ! -f "$PREFIX/lib/libvulkan.so.1" ] && [ ! -f "$PREFIX/lib/libvulkan.so" ]; then
    echo "ERROR: Vulkan loader (libvulkan.so.1) not found in $PREFIX/lib." >&2
    echo "Run build-loader.sh first." >&2
    exit 1
fi
if [ ! -f "$PREFIX/include/vulkan/vulkan_core.h" ]; then
    echo "ERROR: Vulkan-Headers not found in $PREFIX/include." >&2
    echo "Run build-loader.sh first (it installs the headers)." >&2
    exit 1
fi

# --- Prebuilt fast path -----------------------------------------------------

ART_LIB="$SCRIPT_DIR/lib-artifacts.sh"
if [ ! -f "$ART_LIB" ]; then
    ftp -4 -o "$ART_LIB" "$RAW_BASE/lib-artifacts.sh" >/dev/null 2>&1 || true
fi
if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
    . "$ART_LIB"
    echo ""
    echo "=====> Checking for a prebuilt Vulkan-Tools artifact"
    if try_fetch_artifact vulkan-tools; then
        if command -v vulkaninfo >/dev/null 2>&1; then
            echo "Installed prebuilt vulkaninfo - skipping source build."
            # Still run it below by falling through is not done here; just report.
            echo "Run 'vulkaninfo' to test the stack."
            exit 0
        fi
        echo "Prebuilt installed but vulkaninfo not on PATH; building from source."
    fi
fi

# --- Resume detection -------------------------------------------------------

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/Vulkan-Tools/build/CMakeCache.txt" ]; then
    RESUME=1
fi

# --- Phase functions --------------------------------------------------------

phase_clone() {
    if [ "$RESUME" -eq 1 ]; then
        echo "Existing configured build found - resuming; using existing source."
        echo "(If a resumed build later fails oddly, re-run with --clean.)"
        cd "$SRCDIR/Vulkan-Tools"
        return 0
    fi
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d Vulkan-Tools ]; then
        git clone "$TOOLS_REPO"
    else
        echo "Vulkan-Tools source already present, pulling latest."
        cd Vulkan-Tools && git pull && cd ..
    fi
    cd "$SRCDIR/Vulkan-Tools"
}

phase_configure() {
    cd "$SRCDIR/Vulkan-Tools"
    if [ "$RESUME" -eq 1 ]; then
        echo "Already configured; skipping CMake configure (resuming)."
        return 0
    fi
    if [ -d build ] && [ ! -f build/CMakeCache.txt ]; then rm -rf build; fi
    if [ "$FORCE_CLEAN" -eq 1 ]; then rm -rf build; fi

    # Flag notes:
    #   -DVULKAN_HEADERS_INSTALL_DIR=$PREFIX  use the headers installed earlier
    #   -DVULKAN_LOADER_INSTALL_DIR=$PREFIX   link vulkaninfo against our loader
    #   -DUPDATE_DEPS=OFF                     do not fetch deps over the network
    #   -DBUILD_CUBE=OFF                      skip vkcube (avoids the glslang/
    #                                         shader dependency; we only need
    #                                         vulkaninfo)
    #   -DBUILD_ICD=OFF                       skip the mock ICD (we have a real
    #                                         ICD: Lavapipe)
    #   -DBUILD_WSI_WAYLAND_SUPPORT=OFF       no Wayland; Xcb/Xlib stay on
    #   -DBUILD_TESTS=OFF                     tests not needed
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" \
      -DVULKAN_LOADER_INSTALL_DIR="$PREFIX" \
      -DUPDATE_DEPS=OFF \
      -DBUILD_CUBE=OFF \
      -DBUILD_ICD=OFF \
      -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
      -DBUILD_TESTS=OFF
}

phase_compile() {
    cd "$SRCDIR/Vulkan-Tools"
    cmake --build build -j"$(sysctl -n hw.ncpu)"
}

phase_install() {
    cd "$SRCDIR/Vulkan-Tools"
    cmake --install build
}

# The payoff: actually run vulkaninfo. The loader should find the Lavapipe ICD
# via its manifest in $PREFIX/share/vulkan/icd.d/ and enumerate it. We do NOT
# fail the script if vulkaninfo errors at runtime - a successful BUILD is still
# a real result, and a runtime issue is diagnostic information, not a build
# failure. We surface the outcome clearly either way.
phase_run() {
    if ! command -v vulkaninfo >/dev/null 2>&1; then
        echo "vulkaninfo not found on PATH after install." >&2
        return 1
    fi
    echo "vulkaninfo installed at: $(command -v vulkaninfo)"
    echo ""
    echo "Running vulkaninfo (summary) - this is the end-to-end runtime test..."
    echo "-------------------------------------------------------------------"
    # --summary keeps output short; if it is unsupported, fall back to plain.
    if vulkaninfo --summary 2>&1; then
        :
    else
        echo "(--summary failed or unsupported; trying plain vulkaninfo)"
        vulkaninfo 2>&1 | head -60 || true
    fi
    echo "-------------------------------------------------------------------"
    return 0
}

# --- Run --------------------------------------------------------------------

if [ "$UI" -eq 1 ]; then
    printf '%s== vulkan-netbsd: build vulkaninfo (Vulkan-Tools) ==%s\n' "$UI_BAR" "$UI_RESET"
    printf 'Logging all output to: %s\n' "$LOG"
fi

ui_phase "Cloning Vulkan-Tools"          phase_clone     || { ui_summary; exit 1; }
ui_phase "Configuring (CMake)"           phase_configure || { ui_summary; exit 1; }
ui_build "Compiling vulkaninfo"          phase_compile   || { ui_summary; exit 1; }
ui_phase "Installing to $PREFIX"         phase_install   || { ui_summary; exit 1; }
ui_phase "Running vulkaninfo"            phase_run       || { ui_summary; exit 1; }

ui_summary

echo ""
printf '%svulkaninfo build complete.%s\n' "${UI_OK:-}" "${UI_RESET:-}"
cat << EOF

vulkaninfo is built and installed. The output above is the end-to-end test:

  * If it listed a device such as "llvmpipe (LLVM ...)", the loader found and
    loaded the Lavapipe driver and Vulkan is running on NetBSD.
  * If it reported no devices or an error, the build is still good, but the
    loader/ICD/driver runtime handshake needs investigation. The full output
    is in the log below.

Full log of this run: $LOG
EOF
