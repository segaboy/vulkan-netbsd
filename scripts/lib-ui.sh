#!/bin/sh
#
# lib-ui.sh - Shared phased-progress UI for the vulkan-netbsd build scripts.
#
# Sourced by build-glslang.sh, build-mesa.sh, and install-mesa.sh to give them
# the same look and feel as setup-env.sh: a progress bar, spinner, elapsed
# time, per-step ok/FAILED markers, network-stall detection, and a summary.
#
# The sourcing script must set, before using these functions:
#     LOG    - path to the persistent log file
#     TOTAL  - total number of steps (for the progress bar)
# and initialise: STEP=0, RESULTS="", RUN_START="$(date +%s)"
#
# Public functions:
#     ui_phase  "Label" func   - run a discrete step (spinner + elapsed)
#     ui_build  "Label" func   - run a long compile (live N/total progress)
#     ui_step_ok   "Label"     - mark an inline/skipped step ok (0s)
#     ui_log    "msg"          - timestamped line to the log
#     ui_summary               - print the summary table
#
# func is a shell function name; it is run in a subshell with `set -e` and its
# output is redirected to the log. This is the same mechanism setup-env.sh uses.
#
# This file is not executed directly.

# --- Colours / TTY ----------------------------------------------------------

if [ -t 1 ]; then
    _UI_TTY=1
    UI_RESET=$(printf '\033[0m');   UI_OK=$(printf '\033[1;32m')
    UI_FAIL=$(printf '\033[1;31m'); UI_BAR=$(printf '\033[1;36m')
    UI_WARN=$(printf '\033[1;33m'); UI_DIM=$(printf '\033[2m')
else
    _UI_TTY=0
    UI_RESET=; UI_OK=; UI_FAIL=; UI_BAR=; UI_WARN=; UI_DIM=
fi

_ui_hide_cursor() { [ "$_UI_TTY" = 1 ] && printf '\033[?25l'; }
_ui_show_cursor() { [ "$_UI_TTY" = 1 ] && printf '\033[?25h'; }

UI_BARWIDTH=24
UI_STALL_THRESHOLD=25   # seconds without new log output before flagging a stall

# --- Logging ----------------------------------------------------------------

ui_log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# --- Rendering --------------------------------------------------------------

_ui_render_bar() {
    # $1 current step, $2 total, $3 label
    _cur="$1"; _tot="$2"; _label="$3"
    [ "$_tot" -lt 1 ] && _tot=1
    _filled=$(( _cur * UI_BARWIDTH / _tot ))
    [ "$_filled" -gt "$UI_BARWIDTH" ] && _filled="$UI_BARWIDTH"
    _bar=""; _n=0
    while [ "$_n" -lt "$UI_BARWIDTH" ]; do
        if [ "$_n" -lt "$_filled" ]; then _bar="${_bar}#"; else _bar="${_bar}."; fi
        _n=$(( _n + 1 ))
    done
    printf '\n%s[%s]%s  Step %d/%d\n%s%s%s\n' \
        "$UI_BAR" "$_bar" "$UI_RESET" "$_cur" "$_tot" "$UI_BAR" "$_label" "$UI_RESET"
}

_ui_mark_ok() {
    printf '  %sok%s  %s  %s(%ds)%s\n' "$UI_OK" "$UI_RESET" "$1" "$UI_DIM" "$2" "$UI_RESET"
    RESULTS="${RESULTS}OK|$1|$2
"
}

_ui_mark_fail() {
    printf '  %sFAILED%s  %s  %s(%ds, exit %d)%s\n' \
        "$UI_FAIL" "$UI_RESET" "$1" "$UI_DIM" "$2" "$3" "$UI_RESET"
    RESULTS="${RESULTS}FAIL|$1|$2
"
}

# Extract a progress percentage from the tail of the log, understanding both
# ninja ("[194/822] ...") and cmake+make ("[ 42%] ...") output. Echoes a
# percentage integer, or nothing if none found.
_ui_progress_pct() {
    _tl=$(tail -n 20 "$LOG" 2>/dev/null)
    _nm=$(printf '%s\n' "$_tl" | grep -oE '^\[[0-9]+/[0-9]+\]' | tail -n1 | tr -d '[]')
    if [ -n "$_nm" ]; then
        _cur=${_nm%/*}; _tot=${_nm#*/}
        if [ "$_tot" -gt 0 ] 2>/dev/null; then
            echo $(( _cur * 100 / _tot ))
            return
        fi
    fi
    _pc=$(printf '%s\n' "$_tl" | grep -oE '^\[ *[0-9]+%\]' | tail -n1 | tr -dc '0-9')
    [ -n "$_pc" ] && echo "$_pc"
}

# Spinner. $1 = pid to watch, $2 = label, $3 = "progress" to enable the live
# percentage readout (for compiles). Watches the log size for stalls.
_ui_spin() {
    _spid="$1"; _label="$2"; _mode="$3"
    _frames='|/-\'; _fi=0
    _last_size=-1; _stall=0
    _ui_hide_cursor
    while kill -0 "$_spid" 2>/dev/null; do
        _fi=$(( (_fi + 1) % 4 ))
        _frame=$( printf '%s' "$_frames" | cut -c $(( _fi + 1 )) )
        _now=$(date +%s); _el=$(( _now - PHASE_START ))
        _mm=$(( _el / 60 )); _ss=$(( _el % 60 ))

        _size=$( wc -c < "$LOG" 2>/dev/null || echo 0 )
        if [ "$_size" = "$_last_size" ]; then _stall=$(( _stall + 1 ))
        else _stall=0; _last_size="$_size"; fi

        _pcttext=""
        if [ "$_mode" = "progress" ]; then
            _p=$(_ui_progress_pct)
            [ -n "$_p" ] && _pcttext="  ${UI_BAR}${_p}%${UI_RESET}"
        fi

        if [ "$_stall" -ge "$UI_STALL_THRESHOLD" ]; then
            _note="   ${UI_WARN}(no new output for ${_stall}s - stall?)${UI_RESET}"
        else
            _note=""
        fi

        # Note: _label/_pcttext/_note may contain '%' (e.g. "55%"); print them
        # with %s (not inside the format string) so printf does not mis-parse.
        printf "\r  %s  %s%s%s  [%02d:%02d]" \
            "$_frame" "$UI_DIM" "$_label" "$UI_RESET" "$_mm" "$_ss"
        printf "%s%s   " "$_pcttext" "$_note"
        sleep 1
    done
    printf '\r\033[K'
    _ui_show_cursor
}

# --- Public runners ---------------------------------------------------------

_ui_run() {
    # internal: $1 label, $2 func, $3 mode(progress|"")
    _label="$1"; _fn="$2"; _mode="$3"
    STEP=$(( STEP + 1 ))
    _ui_render_bar "$STEP" "$TOTAL" "$_label"
    ui_log "=== Step $STEP/$TOTAL: $_label ==="
    PHASE_START=$(date +%s)

    ( set -e; "$_fn" ) >> "$LOG" 2>&1 &
    _cpid=$!
    _ui_spin "$_cpid" "$_label" "$_mode"
    wait "$_cpid"; _status=$?

    _dur=$(( $(date +%s) - PHASE_START ))
    if [ "$_status" -eq 0 ]; then
        _ui_mark_ok "$_label" "$_dur"
        return 0
    else
        _ui_mark_fail "$_label" "$_dur" "$_status"
        ui_log "Step $STEP FAILED (exit $_status)"
        return "$_status"
    fi
}

ui_phase() { _ui_run "$1" "$2" ""; }
ui_build() { _ui_run "$1" "$2" "progress"; }

# Mark a step that ran inline (not backgrounded) as ok with 0s - used for
# trivial or skipped steps so they still appear in the bar and summary.
ui_step_ok() {
    STEP=$(( STEP + 1 ))
    _ui_render_bar "$STEP" "$TOTAL" "$1"
    _ui_mark_ok "$1" 0
}

ui_summary() {
    _total_dur=$(( $(date +%s) - RUN_START ))
    printf '\n%s---------------- Summary ----------------%s\n' "$UI_BAR" "$UI_RESET"
    printf '%s\n' "$RESULTS" | while IFS='|' read -r _st _name _secs; do
        [ -z "$_name" ] && continue
        if [ "$_st" = "OK" ]; then
            printf '  %sok  %s%-34s %ss\n' "$UI_OK" "$UI_RESET" "$_name" "$_secs"
        else
            printf '  %sX   %s%-34s %ss\n' "$UI_FAIL" "$UI_RESET" "$_name" "$_secs"
        fi
    done
    printf '%s-----------------------------------------%s\n' "$UI_BAR" "$UI_RESET"
    printf '  total: %dm %ds\n' "$(( _total_dur / 60 ))" "$(( _total_dur % 60 ))"
}
