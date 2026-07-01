#!/bin/sh
#
# lib-artifacts.sh — Shared helpers for the prebuilt-binary fast path.
#
# Sourced by build-glslang.sh and build-mesa.sh. Provides:
#   compute_fingerprint      - print an environment fingerprint string
#   try_fetch_artifact NAME   - try to download + install a matching prebuilt
#                               artifact from a GitHub Release. Returns 0 if the
#                               artifact was installed (caller should SKIP the
#                               source build); returns non-zero otherwise
#                               (caller should build from source).
#
# This file is not executed directly.
#
# --- Configuration ----------------------------------------------------------
#
# Which GitHub Release tag to pull prebuilt artifacts from. Override at runtime
# with the ARTIFACT_TAG environment variable, e.g.:
#     ARTIFACT_TAG=prebuilt-2026Q2 sh build-mesa.sh
#
: "${ARTIFACT_TAG:=prebuilt-latest}"
: "${ARTIFACT_REPO:=segaboy/vulkan-netbsd}"

ARTIFACT_BASEURL="https://github.com/${ARTIFACT_REPO}/releases/download/${ARTIFACT_TAG}"
ARTIFACT_TMPDIR="/tmp/vulkan-netbsd-artifacts"
PREFIX="${PREFIX:-/usr/pkg}"

# --- Fingerprint ------------------------------------------------------------
#
# A prebuilt binary is only safe to use on a machine matching the one it was
# built on. The fingerprint captures the things that actually affect binary
# compatibility: OS version, architecture, LLVM version, and pkgsrc branch.
# If any of these differ, the cached binary may not load (unresolved libs), so
# the scripts fall back to building from source.
#
compute_fingerprint() {
    _fp_os="netbsd$(uname -r)"
    _fp_arch="$(uname -m)"

    if command -v llvm-config >/dev/null 2>&1; then
        _fp_llvm="llvm$(llvm-config --version 2>/dev/null)"
    else
        _fp_llvm="llvmNONE"
    fi

    # pkgsrc branch, if recorded during setup (best-effort).
    if [ -f /usr/pkgsrc/.pkgsrc_branch ]; then
        _fp_pkgsrc="pkgsrc$(cat /usr/pkgsrc/.pkgsrc_branch)"
    else
        _fp_pkgsrc="pkgsrcUNKNOWN"
    fi

    printf '%s_%s_%s_%s\n' "$_fp_os" "$_fp_arch" "$_fp_llvm" "$_fp_pkgsrc"
}

# --- Small fetch helper -----------------------------------------------------
# Uses ftp(1) (NetBSD base) which handles http/https. Returns non-zero on any
# failure (including HTTP 404), so a missing artifact cleanly triggers fallback.
_fetch() {
    _url="$1"; _out="$2"
    ftp -o "$_out" "$_url" >/dev/null 2>&1
}

# --- try_fetch_artifact -----------------------------------------------------
# $1 = logical artifact name (e.g. "glslang", "mesa")
#
# Looks for two release assets:
#     <name>-<fingerprint>.tar.gz
#     <name>-<fingerprint>.tar.gz.fingerprint   (contains the fingerprint text)
#
# If the tarball for THIS machine's fingerprint exists, it is downloaded,
# verified, and extracted into PREFIX. Returns 0 on success (skip build).
#
try_fetch_artifact() {
    _name="$1"
    _fp="$(compute_fingerprint)"
    _asset="${_name}-${_fp}.tar.gz"
    _url="${ARTIFACT_BASEURL}/${_asset}"

    echo "  Fingerprint: $_fp"
    echo "  Looking for prebuilt: $_asset"

    mkdir -p "$ARTIFACT_TMPDIR"
    _tarball="${ARTIFACT_TMPDIR}/${_asset}"

    if ! _fetch "$_url" "$_tarball"; then
        echo "  No matching prebuilt artifact found (or download failed)."
        echo "  -> Falling back to building $_name from source."
        rm -f "$_tarball"
        return 1
    fi

    # Sanity check: the download should be a gzip tarball, not an HTML 404 page
    # that some servers return with a 200 status.
    if ! gzip -t "$_tarball" >/dev/null 2>&1; then
        echo "  Downloaded file is not a valid gzip archive (likely a 404 page)."
        echo "  -> Falling back to building $_name from source."
        rm -f "$_tarball"
        return 1
    fi

    echo "  Prebuilt artifact found and valid. Installing into $PREFIX ..."
    if tar -xzf "$_tarball" -C "$PREFIX"; then
        echo "  Installed prebuilt $_name (fingerprint $_fp)."
        rm -f "$_tarball"
        return 0
    else
        echo "  Extraction failed."
        echo "  -> Falling back to building $_name from source."
        rm -f "$_tarball"
        return 1
    fi
}
