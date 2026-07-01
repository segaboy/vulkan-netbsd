#!/bin/sh
#
# setup-env.sh — Prepare a minimal NetBSD 10.1 (amd64) install for building
#                the Vulkan software stack (Mesa/Lavapipe).
#
# Scope:  Fresh, minimal NetBSD 10.1 amd64 install (base ISO, no extra sets).
#         Run as root. Assumes a working network connection (NAT is fine).
#
# What it does:  installs the compiler + X11 sets, bootstraps pkgsrc, sets up
#                the build environment, and installs all build dependencies.
#
# This is a living script and mirrors docs/01-environment-setup.md. It does
# NOT build Mesa — it only prepares the environment.
#
# Usage:
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/setup-env.sh
#     sh setup-env.sh
#

set -e   # stop on the first error

# --- Configuration ----------------------------------------------------------

NETBSD_VERSION="10.1"
ARCH="amd64"
PKGSRC_BRANCH="pkgsrc-2026Q2"
SETS_URL="https://cdn.NetBSD.org/pub/NetBSD/NetBSD-${NETBSD_VERSION}/${ARCH}/binary/sets"
PKGSRC_URL="https://cdn.NetBSD.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz"
PKG_PATH_URL="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/${ARCH}/${NETBSD_VERSION}/All"

WORKDIR="/root"

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

say "Verifying system"
uname -a
df -h /

# --- Step 1: Install the compiler set ---------------------------------------

say "Installing compiler set (comp)"
cd "$WORKDIR"
if ! command -v cc >/dev/null 2>&1; then
    ftp "${SETS_URL}/comp.tar.xz"
    tar -xpJf comp.tar.xz -C /
    rm -f comp.tar.xz
    echo "Compiler set installed."
else
    echo "Compiler already present, skipping."
fi
cc --version

# --- Step 2: Install the X11 sets -------------------------------------------

say "Installing X11 sets (xbase, xcomp)"
cd "$WORKDIR"
if [ ! -d /usr/X11R7/lib ]; then
    ftp "${SETS_URL}/xbase.tar.xz"
    ftp "${SETS_URL}/xcomp.tar.xz"
    tar -xpJf xbase.tar.xz -C /
    tar -xpJf xcomp.tar.xz -C /
    rm -f xbase.tar.xz xcomp.tar.xz
    echo "X11 sets installed."
else
    echo "X11 sets already present, skipping."
fi

# --- Step 3: Fetch and bootstrap pkgsrc -------------------------------------

say "Fetching and bootstrapping pkgsrc (${PKGSRC_BRANCH})"
if [ ! -d /usr/pkgsrc ]; then
    cd "$WORKDIR"
    ftp "$PKGSRC_URL"
    tar -xzf pkgsrc.tar.gz -C /usr
    rm -f pkgsrc.tar.gz
else
    echo "pkgsrc tree already present."
fi

if [ ! -x /usr/pkg/bin/bmake ]; then
    rm -rf /usr/pkgsrc/bootstrap/work
    cd /usr/pkgsrc/bootstrap
    ./bootstrap --prefix /usr/pkg
else
    echo "pkgsrc already bootstrapped, skipping."
fi

# --- Step 4: Configure the environment --------------------------------------

say "Configuring build environment"

export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
export PKG_PATH="$PKG_PATH_URL"
export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
export LDFLAGS="-L/usr/X11R7/lib -Wl,-R/usr/X11R7/lib -L/usr/pkg/lib -Wl,-R/usr/pkg/lib"
export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"

# Persist to .profile (only if not already added)
if ! grep -q "VULKAN-NETBSD ENV" /root/.profile 2>/dev/null; then
    cat >> /root/.profile << 'EOF'

# --- VULKAN-NETBSD ENV ---
export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
export PKG_PATH="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.1/All"
export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
export LDFLAGS="-L/usr/X11R7/lib -Wl,-R/usr/X11R7/lib -L/usr/pkg/lib -Wl,-R/usr/pkg/lib"
export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"
# --- END VULKAN-NETBSD ENV ---
EOF
    echo "Environment variables added to /root/.profile"
else
    echo "Environment already configured in /root/.profile, skipping."
fi

# --- Step 5: Install core packages and build tools --------------------------

say "Installing core packages and build tools"
# ninja may conflict harmlessly with ninja-build; the || true keeps us going
pkg_add cmake git mozilla-rootcerts-openssl || true
pkg_add meson python312 pkgconf py312-mako || true
pkg_add ninja || echo "ninja conflict is harmless (ninja-build provides the binary)"

# --- Step 6: python3 symlink ------------------------------------------------

say "Creating python3 symlink"
if [ -x /usr/pkg/bin/python3.12 ]; then
    ln -sf /usr/pkg/bin/python3.12 /usr/pkg/bin/python3
    python3 --version
fi

# --- Step 7: Install LLVM ---------------------------------------------------

say "Installing LLVM"
pkg_add llvm || true
llvm-config --version

# --- Step 8: Verify base libraries ------------------------------------------

say "Verifying base libraries"
echo "libdrm:     $(pkg-config --modversion libdrm 2>/dev/null || echo MISSING)"
echo "xshmfence:  $(pkg-config --modversion xshmfence 2>/dev/null || echo MISSING)"

# --- Done -------------------------------------------------------------------

say "Environment setup complete"
cat << 'EOF'
The build environment is ready.

IMPORTANT: The environment variables were added to /root/.profile but are not
active in your current shell unless you started it fresh. To load them now:

    . /root/.profile

Next step: clone Mesa and configure the build (see docs/02-mesa-build.md).
EOF
