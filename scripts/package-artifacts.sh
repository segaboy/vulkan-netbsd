#!/bin/sh
#
# package-artifacts.sh — Package the from-source builds (glslang, Mesa) into
#                        prebuilt tarballs for upload to a GitHub Release.
#
# Run this ONCE on a machine where you have already built and installed glslang
# and Mesa (via build-glslang.sh and build-mesa.sh --build). It produces, in
# /root/artifacts/:
#
#     glslang-<fingerprint>.tar.gz          (+ .fingerprint)
#     mesa-<fingerprint>.tar.gz             (+ .fingerprint)
#
# You then upload those files as assets on a GitHub Release, and point the build
# scripts at that release's tag (ARTIFACT_TAG in lib-artifacts.sh, or the env
# var). The build scripts will fetch and install them on matching machines,
# skipping the source build.
#
# Run as root.
#
set -e

PREFIX="${PREFIX:-/usr/pkg}"
OUTDIR="/root/artifacts"
MESA_BUILD="/usr/src/graphics/mesa/build"

# Pull in compute_fingerprint from the shared lib (same directory as this script).
SCRIPT_DIR="$(dirname "$0")"
if [ -f "$SCRIPT_DIR/lib-artifacts.sh" ]; then
    . "$SCRIPT_DIR/lib-artifacts.sh"
else
    echo "ERROR: lib-artifacts.sh not found next to this script." >&2
    echo "Fetch it alongside package-artifacts.sh and retry." >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run as root." >&2
    exit 1
fi

FP="$(compute_fingerprint)"
echo "Environment fingerprint: $FP"
mkdir -p "$OUTDIR"

# ----------------------------------------------------------------------------
# glslang: the installed files under PREFIX. We capture the binary, libs, and
# headers that `cmake --install` placed. Packaging by explicit paths keeps the
# tarball scoped to glslang rather than all of PREFIX.
# ----------------------------------------------------------------------------
echo ""
echo "=====> Packaging glslang"
GLSLANG_PATHS=""
for p in \
    bin/glslangValidator \
    bin/glslang \
    bin/spirv-remap \
    lib/libglslang.a \
    lib/libglslang-default-resource-limits.a \
    lib/libSPIRV.a \
    lib/libSPVRemapper.a \
    include/glslang \
    lib/cmake/glslang ; do
    if [ -e "$PREFIX/$p" ]; then
        GLSLANG_PATHS="$GLSLANG_PATHS $p"
    fi
done

if [ -n "$GLSLANG_PATHS" ]; then
    # shellcheck disable=SC2086
    tar -czf "$OUTDIR/glslang-${FP}.tar.gz" -C "$PREFIX" $GLSLANG_PATHS
    echo "$FP" > "$OUTDIR/glslang-${FP}.tar.gz.fingerprint"
    echo "  Wrote $OUTDIR/glslang-${FP}.tar.gz"
else
    echo "  WARNING: no glslang files found under $PREFIX - did you build it?"
fi

# ----------------------------------------------------------------------------
# Mesa: the Lavapipe driver and its ICD manifest. These are the artifacts that
# matter for a Vulkan build. We package the built driver from the build tree
# plus whatever `ninja install` placed under PREFIX/share/vulkan.
# ----------------------------------------------------------------------------
echo ""
echo "=====> Packaging Mesa (Lavapipe)"
MESA_STAGE="$ARTIFACT_TMPDIR/mesa-stage"
rm -rf "$MESA_STAGE"
mkdir -p "$MESA_STAGE"

LVP_SO="$MESA_BUILD/src/gallium/targets/lavapipe/libvulkan_lvp.so"
if [ -f "$LVP_SO" ]; then
    mkdir -p "$MESA_STAGE/lib"
    cp "$LVP_SO" "$MESA_STAGE/lib/"
else
    echo "  WARNING: $LVP_SO not found - did you run build-mesa.sh --build?"
fi

# ICD manifest(s) installed by ninja install, if present.
if [ -d "$PREFIX/share/vulkan/icd.d" ]; then
    mkdir -p "$MESA_STAGE/share/vulkan"
    cp -R "$PREFIX/share/vulkan/icd.d" "$MESA_STAGE/share/vulkan/"
fi

if [ -n "$(ls -A "$MESA_STAGE" 2>/dev/null)" ]; then
    tar -czf "$OUTDIR/mesa-${FP}.tar.gz" -C "$MESA_STAGE" .
    echo "$FP" > "$OUTDIR/mesa-${FP}.tar.gz.fingerprint"
    echo "  Wrote $OUTDIR/mesa-${FP}.tar.gz"
else
    echo "  WARNING: nothing staged for Mesa - skipping tarball."
fi

rm -rf "$MESA_STAGE"

echo ""
echo "=====> Done"
echo "Artifacts are in $OUTDIR:"
ls -la "$OUTDIR"
cat << EOF

Next steps:
  1. Create a GitHub Release (e.g. tag 'prebuilt-latest' or 'prebuilt-${FP}').
  2. Upload the .tar.gz files above as release assets.
  3. Point the build scripts at that tag, either by editing ARTIFACT_TAG in
     scripts/lib-artifacts.sh, or at runtime:
         ARTIFACT_TAG=<your-tag> sh build-mesa.sh

On a machine whose fingerprint matches ($FP), the build scripts will then fetch
and install these instead of building from source.
EOF
