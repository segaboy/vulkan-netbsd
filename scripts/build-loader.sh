#!/bin/sh
#
# build-loader.sh - Build and install the Khronos Vulkan-Loader (libvulkan.so.1)
#                   on NetBSD, plus Vulkan-Headers (its required dependency).
#
# Scope:  Run AFTER setup-env.sh (and typically after the Mesa/Lavapipe driver
#         is installed). Neither Vulkan-Headers nor Vulkan-Loader is available
#         as a NetBSD binary package, so both are built from source.
#
# The loader is the library applications link against (libvulkan.so.1). At
# runtime it discovers installed ICDs (like Lavapipe) via their manifests in
# /usr/pkg/share/vulkan/icd.d/ and dispatches Vulkan calls to them.
#
# Run as root, with a working network connection.
#
# Usage:
#     ftp -4 https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-loader.sh
#     sh build-loader.sh            # build + install headers and loader
#     sh build-loader.sh --clean    # force a fresh build from scratch
#
# If a build is interrupted or the machine crashes, run the same command again:
# the script detects the existing configured loader build and RESUMES it.
# Use --clean to override and rebuild from scratch.
#
# All output is also written to /root/vulkan-netbsd-loader.log
#

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
HEADERS_REPO="https://github.com/KhronosGroup/Vulkan-Headers.git"
LOADER_REPO="https://github.com/KhronosGroup/Vulkan-Loader.git"
LOG="/root/vulkan-netbsd-loader.log"
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
    echo "# build-loader.sh run: $(date)   args: $*"
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
TOTAL=6
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

# --- Prebuilt fast path -----------------------------------------------------
# If a prebuilt loader artifact matching this machine's environment exists on
# the configured GitHub Release, install it instead of building from source.
# Set ARTIFACT_TAG to choose the release; NO_PREBUILT=1 forces a source build.

ART_LIB="$SCRIPT_DIR/lib-artifacts.sh"
if [ ! -f "$ART_LIB" ]; then
    ftp -4 -o "$ART_LIB" "$RAW_BASE/lib-artifacts.sh" >/dev/null 2>&1 || true
fi
if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
    . "$ART_LIB"
    echo ""
    echo "=====> Checking for a prebuilt Vulkan-Loader artifact"
    if try_fetch_artifact loader; then
        if [ -f "$PREFIX/lib/libvulkan.so.1" ] || [ -f "$PREFIX/lib/libvulkan.so" ]; then
            echo "Installed prebuilt Vulkan-Loader - skipping source build."
            ls -la "$PREFIX"/lib/libvulkan.so* 2>/dev/null
            exit 0
        fi
        echo "Prebuilt installed but libvulkan not found; building from source."
    fi
fi

# --- Resume detection -------------------------------------------------------
# Resume the loader build if a configured CMake build dir exists. --clean
# forces a fresh build; a partial dir (no cache) is rebuilt clean.

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/Vulkan-Loader/build/CMakeCache.txt" ]; then
    RESUME=1
fi

# --- Phase functions --------------------------------------------------------

# Vulkan-Headers: header-only. Installs headers + the Vulkan registry (vk.xml)
# that the loader needs for code generation. Idempotent: skipped if already
# installed, unless --clean.
phase_headers() {
    if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$PREFIX/include/vulkan/vulkan_core.h" ]; then
        echo "Vulkan-Headers already installed, skipping."
        return 0
    fi
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d Vulkan-Headers ]; then
        git clone "$HEADERS_REPO"
    else
        echo "Vulkan-Headers source already present, pulling latest."
        cd Vulkan-Headers && git pull && cd ..
    fi
    cd "$SRCDIR/Vulkan-Headers"
    rm -rf build
    cmake -B build -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --install build
}

phase_clone_loader() {
    if [ "$RESUME" -eq 1 ]; then
        echo "Existing configured loader build found - resuming; using existing source."
        echo "(If a resumed build later fails oddly, re-run with --clean.)"
        cd "$SRCDIR/Vulkan-Loader"
        return 0
    fi
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d Vulkan-Loader ]; then
        git clone "$LOADER_REPO"
    else
        echo "Vulkan-Loader source already present, pulling latest."
        cd Vulkan-Loader && git pull && cd ..
    fi
    cd "$SRCDIR/Vulkan-Loader"
}

phase_configure_loader() {
    cd "$SRCDIR/Vulkan-Loader"
    if [ "$RESUME" -eq 1 ]; then
        echo "Already configured; skipping CMake configure (resuming)."
        return 0
    fi
    if [ -d build ] && [ ! -f build/CMakeCache.txt ]; then rm -rf build; fi
    if [ "$FORCE_CLEAN" -eq 1 ]; then rm -rf build; fi

    # Flag notes (NetBSD specifics):
    #   -DUSE_GAS=OFF
    #       The loader has GNU-assembler code for "unknown function handling"
    #       that is only supported on a fixed list of platforms (Windows, Linux,
    #       Arm). NetBSD is not on that list, so we disable the assembly path and
    #       fall back to the portable C implementation. This is the loader's
    #       NetBSD-portability landmine, analogous to Mesa's %m issue.
    #   -DVULKAN_HEADERS_INSTALL_DIR=$PREFIX
    #       Point the loader at the Vulkan-Headers we just installed (headers +
    #       the vk.xml registry it needs), rather than fetching its own.
    #   -DUPDATE_DEPS=OFF
    #       Do not let the build fetch dependencies over the network; we supply
    #       the headers ourselves.
    #   -DBUILD_WSI_WAYLAND_SUPPORT=OFF
    #       No Wayland on this setup. Xcb/Xlib support stays on (default) and is
    #       satisfied by the X11 libraries from the xbase/xcomp sets.
    #   -DBUILD_TESTS=OFF
    #       We only need the loader library, not its test suite.
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" \
      -DUPDATE_DEPS=OFF \
      -DUSE_GAS=OFF \
      -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
      -DBUILD_TESTS=OFF
}

phase_compile_loader() {
    cd "$SRCDIR/Vulkan-Loader"
    cmake --build build -j"$(sysctl -n hw.ncpu)"
}

phase_install_loader() {
    cd "$SRCDIR/Vulkan-Loader"
    cmake --install build
}

phase_verify() {
    _so=""
    for cand in "$PREFIX/lib/libvulkan.so.1" "$PREFIX/lib/libvulkan.so"; do
        [ -f "$cand" ] && _so="$cand" && break
    done
    if [ -z "$_so" ]; then
        echo "ERROR: libvulkan.so(.1) not found under $PREFIX/lib after install." >&2
        return 1
    fi
    echo "Loader installed: $_so"
    ls -la "$PREFIX"/lib/libvulkan.so* 2>/dev/null
    echo ""
    echo "Shared-library dependencies:"
    ldd "$_so" 2>/dev/null || echo "(ldd failed)"
}

# --- Run --------------------------------------------------------------------

if [ "$UI" -eq 1 ]; then
    printf '%s== vulkan-netbsd: build Vulkan-Loader ==%s\n' "$UI_BAR" "$UI_RESET"
    printf 'Logging all output to: %s\n' "$LOG"
fi

ui_phase "Installing Vulkan-Headers"        phase_headers         || { ui_summary; exit 1; }
ui_phase "Cloning Vulkan-Loader"            phase_clone_loader    || { ui_summary; exit 1; }
ui_phase "Configuring loader (CMake)"       phase_configure_loader|| { ui_summary; exit 1; }
ui_build "Compiling loader"                 phase_compile_loader  || { ui_summary; exit 1; }
ui_phase "Installing to $PREFIX"            phase_install_loader  || { ui_summary; exit 1; }
ui_phase "Verifying"                        phase_verify          || { ui_summary; exit 1; }

ui_summary

echo ""
printf '%sVulkan-Loader build complete.%s\n' "${UI_OK:-}" "${UI_RESET:-}"
cat << EOF

The Vulkan loader (libvulkan.so.1) is built and installed in $PREFIX/lib.

With the Lavapipe ICD installed (from the Mesa build), the loader should now be
able to discover and load it. To actually exercise the stack you still need a
Vulkan test tool such as vulkaninfo (from Vulkan-Tools), which is a separate
build - that is the next step.

Full log of this run: $LOG
EOF
