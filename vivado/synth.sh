#!/usr/bin/env bash
#
# vivado/synth.sh — non-project-mode Vivado synthesis (optionally
# place/route) of cpu_top from a git snapshot, run in an ASCII-only shadow
# directory. See vivado/synth.tcl for the synthesis steps themselves and
# docs/INTERFACES.md §6/§7 for the port list and the Thai-path workaround
# this mirrors from sim/run.sh.
#
# Usage:
#   vivado/synth.sh [--impl] [--worktree]
#
#   --impl       also run opt_design/place_design/route_design and re-emit
#                timing/utilization reports post-implementation (slow).
#                Without it, this stops after synth_design (fast estimates).
#   --worktree   snapshot rtl/*.v and asm/smoke.hex from the *live working
#                tree* instead of `git archive HEAD`. Only use this when
#                nothing else is concurrently editing rtl/ — the default
#                (no flag) is the last *committed* state, which is safe to
#                run even while another agent has rtl/ mid-edit.
#
# Vivado bin dir overridable via $VIVADO_BIN (default matches CLAUDE.md /
# sim/run.sh: D:/AMDDesigntools/2026.1/Vivado/bin).
#
# Exit code is 0 iff synth_design (and, with --impl, place/route) completed:
# vivado itself must exit 0, the log must contain no "ERROR:" line, and the
# log must contain the synth.tcl sentinel "SYNTH_TCL_DONE". Reports land in
# vivado/reports/{utilization,timing,clocks}.txt plus synth.log/synth.jou.
#
# --- Why this snapshots from HEAD instead of reading rtl/ directly ---------
# Another agent may be concurrently editing files under rtl/ (mid-milestone
# hazard-logic work per CLAUDE.md step 5). Synthesizing a half-edited tree
# would produce a meaningless/misleading report, so by default this takes
# `git archive HEAD -- rtl` — the last *committed* state — rather than the
# live working tree. Pass --worktree to opt into the live tree instead.
#
# --- Why this copies into an ASCII-only shadow dir under %LOCALAPPDATA% ----
# Verified empirically (2026-09-06): Vivado 2026.1 batch mode has the same
# non-ANSI-CWD bug xvlog/xelab/xsim have (see sim/run.sh's header comment).
# A trivial one-module `read_verilog` + `synth_design` run with CWD under
# this repo's Thai path ("OneDrive/เอกสาร/...") failed with:
#   ERROR: [Common 17-69] Command failed: File 'C:/.../??????/.../foo.v'
#   does not exist
# — the path's Thai characters get mangled to '?' and the file can't be
# found — while the identical run from an ASCII-only CWD succeeded cleanly.
# `vivado -mode batch -source <ascii path>.tcl` on its own (with -log/-journal
# also given as plain relative names) does NOT fail merely from being
# launched with a Thai CWD; the failure is specifically in file I/O done
# relative to that CWD (read_verilog, report_* writes, etc.), which is why
# staging the RTL/constraints/script into an ASCII shadow dir and cd-ing
# there before invoking vivado (exactly as sim/run.sh does for xvlog/xelab/
# xsim) fixes it.
# -----------------------------------------------------------------------------

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VIVADO_BIN="${VIVADO_BIN:-/d/AMDDesigntools/2026.1/Vivado/bin}"

usage() {
    echo "Usage: $0 [--impl] [--worktree]" >&2
}

IMPL=0
WORKTREE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --impl)
            IMPL=1
            shift
            ;;
        --worktree)
            WORKTREE=1
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

SHADOW="$(cygpath -u "${LOCALAPPDATA:-$TEMP}")/pcpu_synth"
rm -rf "$SHADOW/rtl" "$SHADOW/asm"
mkdir -p "$SHADOW/rtl" "$SHADOW/asm"

if [ "$WORKTREE" -eq 1 ]; then
    echo "== copying rtl/ and asm/smoke.hex from the live working tree (--worktree) =="
    cp -f "$REPO_ROOT"/rtl/*.v "$SHADOW/rtl/" || { echo "ERROR: failed to copy rtl/*.v from working tree" >&2; exit 1; }
    cp -f "$REPO_ROOT/asm/smoke.hex" "$SHADOW/asm/smoke.hex" || { echo "ERROR: failed to copy asm/smoke.hex from working tree" >&2; exit 1; }
else
    echo "== snapshotting rtl/ and asm/smoke.hex from 'git archive HEAD' (committed state only) =="
    (cd "$REPO_ROOT" && git archive HEAD -- rtl) | tar -x -C "$SHADOW"
    if [ $? -ne 0 ]; then
        echo "ERROR: git archive HEAD -- rtl | tar -x failed" >&2
        exit 1
    fi
    (cd "$REPO_ROOT" && git archive HEAD -- asm/smoke.hex) | tar -x -C "$SHADOW"
    if [ $? -ne 0 ]; then
        echo "ERROR: git archive HEAD -- asm/smoke.hex | tar -x failed" >&2
        exit 1
    fi
fi

cp -f "$REPO_ROOT/vivado/constraints.xdc" "$SHADOW/constraints.xdc"
cp -f "$REPO_ROOT/vivado/synth.tcl" "$SHADOW/synth.tcl"

cd "$SHADOW" || exit 1
rm -f synth.log synth.jou utilization.txt timing.txt clocks.txt

VIVADO_ARGS=(-mode batch -source synth.tcl -log synth.log -journal synth.jou)
if [ "$IMPL" -eq 1 ]; then
    VIVADO_ARGS+=(-tclargs --impl)
fi

echo "== vivado (cwd=$SHADOW) =="
"$VIVADO_BIN/vivado.bat" "${VIVADO_ARGS[@]}"
VIVADO_RC=$?

REPORTS_DIR="$REPO_ROOT/vivado/reports"
mkdir -p "$REPORTS_DIR"

for f in synth.log synth.jou utilization.txt timing.txt clocks.txt; do
    if [ -f "$SHADOW/$f" ]; then
        cp -f "$SHADOW/$f" "$REPORTS_DIR/$f"
    fi
done

if [ "$VIVADO_RC" -ne 0 ]; then
    echo "FAIL: vivado exited $VIVADO_RC" >&2
    exit 1
fi

# Anchored to line start: Vivado's own log lines never begin with anything
# but the message code itself (e.g. "ERROR: [Common 17-69] ..."), while the
# source-echo lines it prints for every sourced Tcl statement are prefixed
# with "# " (e.g. "#     puts \"ERROR: no rtl/*.v files found ...\""), which
# would otherwise false-positive on this script's own error-message strings.
if [ -f "$SHADOW/synth.log" ] && grep -qE "^ERROR:" "$SHADOW/synth.log"; then
    echo "FAIL: synth.log contains ERROR: line(s):" >&2
    grep -E "^ERROR:" "$SHADOW/synth.log" >&2
    exit 1
fi

if [ ! -f "$SHADOW/synth.log" ] || ! grep -q "SYNTH_TCL_DONE" "$SHADOW/synth.log"; then
    echo "FAIL: synth.log missing SYNTH_TCL_DONE sentinel -- synth_design likely did not complete" >&2
    exit 1
fi

echo "PASS: synthesis complete. Reports in $REPORTS_DIR"
exit 0
