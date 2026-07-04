#!/bin/sh
#
# build-mesa.sh - Clone, configure, and build Mesa with the Vulkan software
#                 driver (Lavapipe / swrast) on NetBSD.
#
# Scope:  Run AFTER setup-env.sh and build-glslang.sh. Clones Mesa, installs
#         the last few build tools it needs (bison, flex), configures with
#         Meson targeting the Lavapipe software Vulkan driver, and (with
#         --build) compiles and installs it.
#
# STATUS: Mesa configures, compiles, and LINKS the Lavapipe Vulkan driver
#         (libvulkan_lvp.so) on NetBSD 10.1 with the -Wno-error=format
#         workaround below. This is a build-and-link result; runtime execution
#         is out of scope (software-only, no GPU under VirtualBox).
#
# Run as root, with a working network connection.
#
# Usage:
#     ftp -4 https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-mesa.sh
#     sh build-mesa.sh            # clone + configure only
#     sh build-mesa.sh --build    # also compile + install the Lavapipe driver
#     sh build-mesa.sh --build --clean   # force a fresh build from scratch
#
# If a build is interrupted or the machine crashes, just run the same command
# again: the script detects the existing configured build and RESUMES it
# automatically (ninja rebuilds only what is missing). Use --clean to override
# this and rebuild from scratch.
#
# All output is also written to /root/vulkan-netbsd-mesa.log
#

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build"
LOG="/root/vulkan-netbsd-mesa.log"
RAW_BASE="https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts"

DO_BUILD=0
FORCE_CLEAN=0
for _arg in "$@"; do
    case "$_arg" in
        --build) DO_BUILD=1 ;;
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
    echo "# build-mesa.sh run: $(date)   args: $*"
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
if [ "$DO_BUILD" -eq 1 ]; then TOTAL=5; else TOTAL=3; fi
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
if ! python3 -c "from packaging.version import Version; import mako, yaml" 2>/dev/null; then
    echo "ERROR: python3 is missing mako, yaml, or packaging." >&2
    echo "Run setup-env.sh (it installs these), or:" >&2
    echo "    pkg_add py312-mako py312-yaml py312-packaging" >&2
    exit 1
fi

# --- Prebuilt fast path -----------------------------------------------------
# On --build, if a prebuilt Mesa (Lavapipe) artifact matching this machine's
# environment exists on the configured GitHub Release, install it instead of
# building. Falls back to the source build on any mismatch or failure. Set
# ARTIFACT_TAG to choose the release; NO_PREBUILT=1 forces a source build. A
# configure-only run always proceeds to configure from source.

if [ "$DO_BUILD" -eq 1 ]; then
    ART_LIB="$SCRIPT_DIR/lib-artifacts.sh"
    if [ ! -f "$ART_LIB" ]; then
        ftp -4 -o "$ART_LIB" "$RAW_BASE/lib-artifacts.sh" >/dev/null 2>&1 || true
    fi
    if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
        . "$ART_LIB"
        echo ""
        echo "=====> Checking for a prebuilt Mesa (Lavapipe) artifact"
        if try_fetch_artifact mesa; then
            echo "Installed prebuilt Mesa - skipping clone + compile."
            echo "Verify with:"
            echo "    ls -la $PREFIX/lib/libvulkan_lvp.so"
            echo "    ls    $PREFIX/share/vulkan/icd.d/"
            exit 0
        fi
    fi
fi

# --- Resume detection -------------------------------------------------------
# If a previously configured build directory exists (has build.ninja), RESUME
# from it instead of wiping. --clean forces a fresh build; a partial dir (no
# build.ninja) is treated as broken and rebuilt clean.

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/mesa/$BUILD_DIR/build.ninja" ]; then
    RESUME=1
fi

# --- Phase functions --------------------------------------------------------

phase_tools() {
    # Mesa accepts bison or byacc and needs flex for the lexer. Install both.
    pkg_add bison flex || echo "note: bison/flex may already be present"
}

phase_clone() {
    if [ "$RESUME" -eq 1 ]; then
        echo "Existing configured build found - resuming; using existing source as-is."
        echo "(If a resumed build later fails oddly, re-run with --clean.)"
        cd "$SRCDIR/mesa"
        return 0
    fi
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d mesa ]; then
        git clone "$MESA_REPO"
    else
        echo "Mesa source already present, pulling latest."
        cd mesa && git pull && cd ..
    fi
    cd "$SRCDIR/mesa"
}

phase_configure() {
    cd "$SRCDIR/mesa"
    if [ "$RESUME" -eq 1 ]; then
        echo "Already configured; skipping Meson configure (resuming)."
        return 0
    fi
    # Wipe any previous build dir for a clean, reproducible configure.
    rm -rf "$BUILD_DIR"

    # Flag notes:
    #   -Dvulkan-drivers=swrast     Lavapipe, the software Vulkan driver (target)
    #   -Dgallium-drivers=llvmpipe  LLVM-backed software rasterizer for Lavapipe
    #   -Dplatforms=x11             window-system integration (X11 from xbase/xcomp)
    #   -Dglx/-Degl/-Dgbm=disabled  turn off OpenGL-adjacent pieces we don't need
    # LLVM is auto-detected via llvm-config on PATH.
    #
    # -Dc_args="-Wno-error=format": Mesa uses the %m format specifier (a
    # glibc/syslog extension) in vk_errorf() calls in vk_drm_syncobj.c. On
    # NetBSD, GCC's -Werror=format rejects %m in non-syslog functions. NetBSD
    # libc supports %m at runtime, so demoting this to a warning is safe. The
    # proper upstreamable fix is to use strerror(errno); tracked as a TODO.
    meson setup "$BUILD_DIR" \
      --prefix="$PREFIX" \
      -Dbuildtype=release \
      -Dvulkan-drivers=swrast \
      -Dgallium-drivers=llvmpipe \
      -Dplatforms=x11 \
      -Dglx=disabled \
      -Degl=disabled \
      -Dgbm=disabled \
      -Dc_args="-Wno-error=format"
}

phase_compile() {
    cd "$SRCDIR/mesa"
    ninja -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
}

phase_install() {
    cd "$SRCDIR/mesa"
    ninja -C "$BUILD_DIR" install
}

# --- Run --------------------------------------------------------------------

if [ "$UI" -eq 1 ]; then
    printf '%s== vulkan-netbsd: build Mesa (Lavapipe) ==%s\n' "$UI_BAR" "$UI_RESET"
    printf 'Logging all output to: %s\n' "$LOG"
fi

ui_phase "Installing bison + flex"                phase_tools     || { ui_summary; exit 1; }
ui_phase "Cloning Mesa"                           phase_clone     || { ui_summary; exit 1; }
ui_phase "Configuring (Meson, Lavapipe)"          phase_configure || { ui_summary; exit 1; }

if [ "$DO_BUILD" -eq 1 ]; then
    ui_build "Compiling Mesa"                     phase_compile   || { ui_summary; exit 1; }
    ui_phase "Installing to $PREFIX"              phase_install   || { ui_summary; exit 1; }
fi

ui_summary

echo ""
if [ "$DO_BUILD" -eq 1 ]; then
    printf '%sMesa build complete.%s\n' "${UI_OK:-}" "${UI_RESET:-}"
    cat << EOF

The Lavapipe Vulkan driver was compiled and installed.
Verify the driver and its ICD manifest:
    ls -la $BUILD_DIR/src/gallium/targets/lavapipe/libvulkan_lvp.so
    ldd    $BUILD_DIR/src/gallium/targets/lavapipe/libvulkan_lvp.so
    ls     $PREFIX/share/vulkan/icd.d/

(install-mesa.sh can re-run the install + verification on its own.)

Full log of this run: $LOG
EOF
else
    printf '%sMesa configure complete.%s\n' "${UI_OK:-}" "${UI_RESET:-}"
    cat << EOF

To compile + install the Lavapipe driver, re-run with --build:
    sh build-mesa.sh --build

Full log of this run: $LOG
EOF
fi
