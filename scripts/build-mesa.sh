#!/bin/sh
#
# build-mesa.sh — Clone and configure Mesa with the Vulkan software driver
#                 (Lavapipe / swrast) on NetBSD.
#
# Scope:  Run AFTER setup-env.sh and build-glslang.sh. Clones Mesa, installs
#         the last few build tools it needs (bison, flex), and runs the Meson
#         configure targeting the Lavapipe software Vulkan driver.
#
# STATUS: Mesa configures, compiles, and LINKS the Lavapipe Vulkan driver
#         (libvulkan_lvp.so) on NetBSD 10.1 with the -Wno-error=format
#         workaround below. This is a build-and-link result; runtime execution
#         is out of scope (software-only, no GPU under VirtualBox). The install
#         step (ninja install) is provided but less exercised than the compile.
#
# Run as root, with a working network connection.
#
# Usage:
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-mesa.sh
#     sh build-mesa.sh            # clone + configure only
#     sh build-mesa.sh --build    # also compile + install the Lavapipe driver
#     sh build-mesa.sh --build --clean   # force a fresh build from scratch
#
# If a build is interrupted or the machine crashes, just run the same command
# again: the script detects the existing configured build and RESUMES it
# automatically (ninja rebuilds only what is missing). Use --clean to override
# this and rebuild from scratch.
#

set -e

# --- Configuration ----------------------------------------------------------

SRCDIR="/usr/src/graphics"
PREFIX="/usr/pkg"
MESA_REPO="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build"
LOG="/root/vulkan-netbsd-mesa.log"

DO_BUILD=0
FORCE_CLEAN=0
for _arg in "$@"; do
    case "$_arg" in
        --build) DO_BUILD=1 ;;
        --clean) FORCE_CLEAN=1 ;;
    esac
done

# --- Persistent logging -----------------------------------------------------
# Capture everything this script prints to a log file (in addition to the
# terminal), so a run can be inspected afterward or after an SSH drop:
#     tail -f /root/vulkan-netbsd-mesa.log
# Re-exec once through tee; the VNB_LOGGING guard prevents an infinite loop.
# Placed after argument parsing so "$@" (e.g. --build) is preserved.
if [ -z "${VNB_LOGGING:-}" ]; then
    VNB_LOGGING=1
    export VNB_LOGGING
    {
        echo "############################################################"
        echo "# build-mesa.sh run: $(date)  args: $*"
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

# --- Prebuilt fast path -----------------------------------------------------
# If a prebuilt Mesa (Lavapipe) artifact matching this machine's environment
# exists on the configured GitHub Release, install it instead of cloning and
# compiling Mesa. Falls back to the source build on any mismatch or failure.
# Set ARTIFACT_TAG to choose the release; set NO_PREBUILT=1 to force a source
# build (useful when refining the build itself).
#
# This only short-circuits when a build artifact is actually wanted (--build);
# a plain configure-only run always proceeds to configure from source.

if [ "$DO_BUILD" -eq 1 ]; then
    ART_LIB="$(dirname "$0")/lib-artifacts.sh"
    if [ ! -f "$ART_LIB" ]; then
        ftp -o "$ART_LIB" \
          "https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/lib-artifacts.sh" \
          >/dev/null 2>&1 || true
    fi

    if [ "${NO_PREBUILT:-0}" != "1" ] && [ -f "$ART_LIB" ]; then
        . "$ART_LIB"
        say "Checking for a prebuilt Mesa (Lavapipe) artifact"
        if try_fetch_artifact mesa; then
            say "Installed prebuilt Mesa - skipping clone + compile"
            echo "Lavapipe driver and ICD manifest installed into $PREFIX."
            echo "Verify with:"
            echo "    ls -la $PREFIX/lib/libvulkan_lvp.so"
            echo "    ls    $PREFIX/share/vulkan/icd.d/"
            exit 0
        fi
    fi
fi

# --- Step 1: Install remaining build tools (bison, flex) --------------------

say "Installing bison and flex (parser/lexer, required by Mesa configure)"
# Mesa accepts bison or byacc; it needs flex for the lexer. Install both.
pkg_add bison flex || echo "note: bison/flex may already be present"

# --- Resume detection -------------------------------------------------------
# If a previously configured build directory exists (has build.ninja), we can
# RESUME from it instead of wiping and starting over - ninja only rebuilds what
# is missing. This makes the script recover automatically from an interrupted
# or crashed build, so a user never has to know how to resume ninja by hand.
#
# --clean (FORCE_CLEAN) overrides this and forces a fresh build from scratch.
# A partially-configured dir (exists but no build.ninja) is treated as broken
# and rebuilt clean, since it cannot be resumed safely.

RESUME=0
if [ "$FORCE_CLEAN" -eq 0 ] && [ -f "$SRCDIR/mesa/$BUILD_DIR/build.ninja" ]; then
    RESUME=1
fi

# --- Step 2: Clone Mesa (or reuse existing source when resuming) -------------

if [ "$RESUME" -eq 1 ]; then
    say "Existing configured build found - RESUMING"
    echo "A previously configured Mesa build directory was found."
    echo "Resuming from where it left off (normal after an interrupted or"
    echo "crashed build). The existing source is used as-is; it is not updated,"
    echo "so the build stays consistent with what was already compiled."
    echo ""
    echo "If the build later fails in a way that makes no sense, start fresh:"
    echo "    sh build-mesa.sh --build --clean"
    cd "$SRCDIR/mesa"
else
    say "Cloning Mesa"
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"
    if [ ! -d mesa ]; then
        git clone "$MESA_REPO"
    else
        echo "Mesa source already present, pulling latest."
        cd mesa && git pull && cd ..
    fi
    cd "$SRCDIR/mesa"
fi

# --- Step 3: Configure with Meson (Lavapipe / swrast) -----------------------
# Skipped entirely when resuming - the existing build.ninja already reflects
# the configured build.

if [ "$RESUME" -eq 1 ]; then
    say "Skipping configure (already configured; resuming build)"
else
    say "Configuring Mesa (Meson) - Vulkan swrast (Lavapipe), gallium llvmpipe"

    # Wipe any previous build dir for a clean, reproducible configure.
    rm -rf "$BUILD_DIR"

    # Flag notes:
    #   -Dvulkan-drivers=swrast     Lavapipe, the software Vulkan driver (target)
    #   -Dgallium-drivers=llvmpipe  LLVM-backed software rasterizer for Lavapipe
    #   -Dplatforms=x11             window-system integration (X11 from xbase/xcomp)
    #   -Dglx/-Degl/-Dgbm=disabled  turn off OpenGL-adjacent pieces we don't need
    # LLVM is auto-detected via llvm-config on PATH (no explicit flag needed).
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

    # NOTE on -Dc_args="-Wno-error=format":
    # Mesa uses the %m format specifier (a glibc/syslog extension expanding to
    # strerror(errno)) in vk_errorf() calls in vk_drm_syncobj.c. On NetBSD, GCC's
    # -Werror=format rejects %m in non-syslog functions, which otherwise fails
    # the build. NetBSD libc supports %m at runtime, so demoting this to a
    # warning is safe for building/linking. The proper upstreamable fix is to
    # replace %m with an explicit strerror(errno) argument; tracked as a TODO.

    say "Meson configure complete"
    echo "Mesa configured successfully with the Vulkan swrast (Lavapipe) driver."
fi

# --- Step 4: (Optional) build -----------------------------------------------

if [ "$DO_BUILD" -eq 1 ]; then
    say "Building Mesa (ninja) - compiles + links libvulkan_lvp.so on NetBSD"
    ninja -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

    say "Installing Mesa to $PREFIX"
    ninja -C "$BUILD_DIR" install

    say "Mesa build + install step finished"
    echo "Verify the Lavapipe Vulkan driver was built:"
    echo "    ls -la $BUILD_DIR/src/gallium/targets/lavapipe/libvulkan_lvp.so"
    echo "    ldd    $BUILD_DIR/src/gallium/targets/lavapipe/libvulkan_lvp.so"
    echo "And that the ICD manifest installed:"
    echo "    ls $PREFIX/share/vulkan/icd.d/"
else
    cat << EOF

Configure complete. To compile + link the Lavapipe driver (confirmed working
on NetBSD with the -Wno-error=format workaround) and install, re-run with:

    sh build-mesa.sh --build

Or run it manually from $SRCDIR/mesa:

    ninja -C $BUILD_DIR -j\$(sysctl -n hw.ncpu)
    ninja -C $BUILD_DIR install
EOF
fi
