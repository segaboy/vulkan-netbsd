#!/bin/sh
#
# setup-env.sh — Prepare a minimal NetBSD 10.1 (amd64) install for building
#                the Vulkan software stack (Mesa/Lavapipe).
#
# Scope:  Fresh, minimal NetBSD 10.1 amd64 install (base ISO, no extra sets).
#         Run as root. Assumes a working network connection.
#
# What it does:  installs the compiler + X11 sets, bootstraps pkgsrc, sets up
#                the build environment, and installs all build dependencies.
#
# This is a living script and mirrors docs/01-environment-setup.md. It does
# NOT build Mesa — it only prepares the environment.
#
# Progress + logging:
#   - Each phase shows a progress bar, spinner, and elapsed time.
#   - ALL command output is written to a persistent log (see LOG below), so if
#     your SSH session drops you can reconnect and inspect it:
#         tail -f /root/vulkan-netbsd-setup.log
#   - The spinner flags a likely network stall if the log stops growing.
#
# Usage (interactive, watch live progress):
#     ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/setup-env.sh
#     sh setup-env.sh
#
# Usage (detached, survives SSH drops on flaky links):
#     nohup sh setup-env.sh >/dev/null 2>&1 &
#     tail -f /root/vulkan-netbsd-setup.log
#
# The script is idempotent: re-running it skips completed steps.
#

# NOTE: global `set -e` is intentionally NOT used. Each phase runs inside a
# subshell with its own `set -e`, and failures are caught and reported per
# phase in the final summary.

# --- Configuration ----------------------------------------------------------

NETBSD_VERSION="10.1"
ARCH="amd64"
PKGSRC_BRANCH="pkgsrc-2026Q2"
SETS_URL="https://cdn.NetBSD.org/pub/NetBSD/NetBSD-${NETBSD_VERSION}/${ARCH}/binary/sets"
PKGSRC_URL="https://cdn.NetBSD.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz"
PKG_PATH_URL="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/${ARCH}/${NETBSD_VERSION}/All"

WORKDIR="/root"
LOG="/root/vulkan-netbsd-setup.log"

STALL_THRESHOLD=25   # seconds without new log output before flagging a stall
BARWIDTH=24
TOTAL=10             # total number of phases

# --- Terminal / color setup -------------------------------------------------

if [ -t 1 ]; then
    IS_TTY=1
    C_RESET=$(printf '\033[0m')
    C_OK=$(printf '\033[1;32m')
    C_FAIL=$(printf '\033[1;31m')
    C_BAR=$(printf '\033[1;36m')
    C_WARN=$(printf '\033[1;33m')
    C_DIM=$(printf '\033[2m')
else
    IS_TTY=0
    C_RESET=; C_OK=; C_FAIL=; C_BAR=; C_WARN=; C_DIM=
fi

hide_cursor() { [ "$IS_TTY" = 1 ] && printf '\033[?25l'; }
show_cursor() { [ "$IS_TTY" = 1 ] && printf '\033[?25h'; }

# Survive SSH hangups so a dropped session doesn't kill the run; restore the
# cursor and bail cleanly on Ctrl-C.
trap '' HUP
trap 'show_cursor; printf "\n%sInterrupted.%s See %s\n" "$C_FAIL" "$C_RESET" "$LOG"; exit 130' INT

# --- State ------------------------------------------------------------------

CURRENT=0
PHASE_START=0
SPIN_LABEL=""
RESULTS=""       # accumulates "STATUS|NAME|SECONDS" lines
RUN_START=$(date +%s)

# --- Logging helper ---------------------------------------------------------

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# --- Progress rendering -----------------------------------------------------

render_bar() {
    # $1 = current phase, $2 = total, $3 = label
    cur="$1"; tot="$2"; label="$3"
    filled=$(( cur * BARWIDTH / tot ))
    bar=""; n=0
    while [ "$n" -lt "$BARWIDTH" ]; do
        if [ "$n" -lt "$filled" ]; then bar="${bar}#"; else bar="${bar}."; fi
        n=$(( n + 1 ))
    done
    printf '\n%s[%s]%s  Phase %d/%d\n%s%s%s\n' \
        "$C_BAR" "$bar" "$C_RESET" "$cur" "$tot" "$C_BAR" "$label" "$C_RESET"
}

# Spinner: animates while $1 (a pid) is alive, showing elapsed time and a
# stall warning if the log file stops growing.
spin() {
    spid="$1"
    frames='|/-\'
    fi=0
    last_size=-1
    stall=0
    hide_cursor
    while kill -0 "$spid" 2>/dev/null; do
        fi=$(( (fi + 1) % 4 ))
        frame=$( printf '%s' "$frames" | cut -c $(( fi + 1 )) )

        now=$(date +%s)
        el=$(( now - PHASE_START ))
        mm=$(( el / 60 )); ss=$(( el % 60 ))

        size=$( wc -c < "$LOG" 2>/dev/null || echo 0 )
        if [ "$size" = "$last_size" ]; then
            stall=$(( stall + 1 ))
        else
            stall=0; last_size="$size"
        fi

        if [ "$stall" -ge "$STALL_THRESHOLD" ]; then
            note="   ${C_WARN}(no new output for ${stall}s - network stall?)${C_RESET}"
        else
            note=""
        fi

        printf '\r  %s  %s%s  [%02d:%02d elapsed]%s   ' \
            "$frame" "$C_DIM" "$SPIN_LABEL" "$mm" "$ss" "$C_RESET"
        printf '%s' "$note"
        sleep 1
    done
    printf '\r\033[K'   # clear the spinner line
    show_cursor
}

# --- Phase runner -----------------------------------------------------------
# run_phase "Label" phase_function
# Runs phase_function in a subshell (with its own set -e), logging all output,
# while showing a spinner. Records pass/fail + duration for the summary.
run_phase() {
    label="$1"; fn="$2"
    CURRENT=$(( CURRENT + 1 ))
    SPIN_LABEL="$label"
    render_bar "$CURRENT" "$TOTAL" "$label"
    log "=== Phase $CURRENT/$TOTAL: $label ==="
    PHASE_START=$(date +%s)

    ( set -e; "$fn" ) >> "$LOG" 2>&1 &
    cpid=$!
    spin "$cpid"
    wait "$cpid"; status=$?

    dur=$(( $(date +%s) - PHASE_START ))
    if [ "$status" -eq 0 ]; then
        printf '  %sok%s  %s  %s(%ds)%s\n' "$C_OK" "$C_RESET" "$label" "$C_DIM" "$dur" "$C_RESET"
        RESULTS="${RESULTS}OK|${label}|${dur}
"
    else
        printf '  %sFAILED%s  %s  %s(%ds, exit %d)%s\n' \
            "$C_FAIL" "$C_RESET" "$label" "$C_DIM" "$dur" "$status" "$C_RESET"
        RESULTS="${RESULTS}FAIL|${label}|${dur}
"
        log "Phase $CURRENT FAILED (exit $status)"
        print_summary
        printf '\n%sSetup failed at phase %d (%s).%s\n' "$C_FAIL" "$CURRENT" "$label" "$C_RESET"
        printf 'Full log: %s\n' "$LOG"
        exit "$status"
    fi
}

print_summary() {
    total_dur=$(( $(date +%s) - RUN_START ))
    printf '\n%s---------------- Summary ----------------%s\n' "$C_BAR" "$C_RESET"
    printf '%s\n' "$RESULTS" | while IFS='|' read -r st name secs; do
        [ -z "$name" ] && continue
        if [ "$st" = "OK" ]; then
            printf '  %sok  %s%-34s %ss\n' "$C_OK" "$C_RESET" "$name" "$secs"
        else
            printf '  %sX   %s%-34s %ss\n' "$C_FAIL" "$C_RESET" "$name" "$secs"
        fi
    done
    printf '%s-----------------------------------------%s\n' "$C_BAR" "$C_RESET"
    printf '  total: %dm %ds\n' "$(( total_dur / 60 ))" "$(( total_dur % 60 ))"
}

# ============================================================================
# Phase definitions
# Each returns 0 on success; any failing command aborts the phase (set -e in
# the subshell) and is reported as a failure.
# ============================================================================

phase_verify() {
    echo "System:"
    uname -a
    echo
    echo "Disk:"
    df -h /
}

phase_compiler() {
    cd "$WORKDIR"
    if command -v cc >/dev/null 2>&1; then
        echo "Compiler already present, skipping."
        return 0
    fi
    ftp "${SETS_URL}/comp.tar.xz"
    tar -xpJf comp.tar.xz -C /
    rm -f comp.tar.xz
    cc --version
}

phase_x11() {
    cd "$WORKDIR"
    if [ -d /usr/X11R7/lib ]; then
        echo "X11 sets already present, skipping."
        return 0
    fi
    ftp "${SETS_URL}/xbase.tar.xz"
    ftp "${SETS_URL}/xcomp.tar.xz"
    tar -xpJf xbase.tar.xz -C /
    tar -xpJf xcomp.tar.xz -C /
    rm -f xbase.tar.xz xcomp.tar.xz
}

phase_pkgsrc() {
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
}

# NOTE: this phase runs INLINE in the parent shell (not via run_phase), because
# it must export variables into the environment that later phases inherit.
apply_env_inline() {
    export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
    export PKG_PATH="$PKG_PATH_URL"
    export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
    export LDFLAGS="-L/usr/X11R7/lib -L/usr/pkg/lib"
    export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"

    if ! grep -q "VULKAN-NETBSD ENV" /root/.profile 2>/dev/null; then
        cat >> /root/.profile << 'EOF'

# --- VULKAN-NETBSD ENV ---
export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
export PKG_PATH="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.1/All"
export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
export LDFLAGS="-L/usr/X11R7/lib -L/usr/pkg/lib"
export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"
# --- END VULKAN-NETBSD ENV ---
EOF
        log "Environment appended to /root/.profile"
    else
        log "Environment already present in /root/.profile"
    fi
    log "Environment configured (PKG_PATH=$PKG_PATH)"
}

phase_core_pkgs() {
    # ninja may conflict harmlessly with ninja-build; tolerate it.
    pkg_add cmake git mozilla-rootcerts-openssl
}

phase_build_tools() {
    pkg_add meson python312 pkgconf py312-mako
    pkg_add ninja || echo "ninja conflict is harmless (ninja-build provides the binary)"
}

phase_python_symlink() {
    if [ -x /usr/pkg/bin/python3.12 ]; then
        ln -sf /usr/pkg/bin/python3.12 /usr/pkg/bin/python3
        python3 --version
    else
        echo "python3.12 not found; cannot create python3 symlink." >&2
        return 1
    fi
}

phase_llvm() {
    pkg_add llvm
    llvm-config --version
}

phase_verify_libs() {
    echo "libdrm:    $(pkg-config --modversion libdrm 2>/dev/null || echo MISSING)"
    echo "xshmfence: $(pkg-config --modversion xshmfence 2>/dev/null || echo MISSING)"
}

# ============================================================================
# Main
# ============================================================================

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

# Start a fresh log section for this run.
{
    echo "############################################################"
    echo "# vulkan-netbsd setup-env.sh run"
    echo "# started: $(date)"
    echo "############################################################"
} >> "$LOG"

printf '%s== vulkan-netbsd environment setup ==%s\n' "$C_BAR" "$C_RESET"
printf 'Logging all output to: %s\n' "$LOG"
printf '%sTip: if your SSH session drops, reconnect and run:%s\n' "$C_DIM" "$C_RESET"
printf '%s      tail -f %s%s\n' "$C_DIM" "$LOG" "$C_RESET"

run_phase "Verifying system"              phase_verify
run_phase "Installing compiler set"       phase_compiler
run_phase "Installing X11 sets"           phase_x11
run_phase "Fetching + bootstrapping pkgsrc" phase_pkgsrc

# Phase 5 runs inline (must mutate the parent environment).
CURRENT=$(( CURRENT + 1 ))
render_bar "$CURRENT" "$TOTAL" "Configuring environment"
log "=== Phase $CURRENT/$TOTAL: Configuring environment ==="
_ps=$(date +%s)
if apply_env_inline; then
    printf '  %sok%s  Configuring environment  %s(%ds)%s\n' \
        "$C_OK" "$C_RESET" "$C_DIM" "$(( $(date +%s) - _ps ))" "$C_RESET"
    RESULTS="${RESULTS}OK|Configuring environment|$(( $(date +%s) - _ps ))
"
else
    printf '  %sFAILED%s  Configuring environment\n' "$C_FAIL" "$C_RESET"
    RESULTS="${RESULTS}FAIL|Configuring environment|0
"
    print_summary
    exit 1
fi

run_phase "Installing core packages"      phase_core_pkgs
run_phase "Installing build tools"        phase_build_tools
run_phase "Creating python3 symlink"      phase_python_symlink
run_phase "Installing LLVM"               phase_llvm
run_phase "Verifying base libraries"      phase_verify_libs

print_summary

printf '\n%sEnvironment setup complete.%s\n' "$C_OK" "$C_RESET"
cat << EOF

The environment variables were written to /root/.profile but are not active in
your current shell. To load them now:

    . /root/.profile

Next step: build glslang, then Mesa.
    sh build-glslang.sh

Full log of this run: $LOG
EOF
