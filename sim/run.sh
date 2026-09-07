#!/usr/bin/env bash
#
# sim/run.sh — compile + elaborate + simulate one testbench with Vivado xsim
# (batch mode, no GUI). See docs/INTERFACES.md §7 for the contract this
# implements.
#
# Usage:
#   sim/run.sh <tb_name> [-g NAME=VALUE ...] [--plusarg +X=Y ...] [--wave]
#                        [--tag TAG] [--elab-only | --sim-only]
#
#   <tb_name>          module name; source must be tb/<tb_name>.v
#   -g NAME=VALUE      repeatable; passed to `xelab -generic_top "NAME=VALUE"`
#   --plusarg +X=Y     repeatable; passed to `xsim -testplusarg X=Y`
#   --wave             adds `-debug typical` at elab and dumps
#                      sim/work/<tb>/<tb>.wdb via `xsim -wdb`. Default off.
#
# Exit code is 0 iff sim/work/<tb>/sim.log contains a line starting with
# "PASS" and no line starting with "FAIL". Compile/elaborate errors are
# always nonzero.
#
# --- Snapshot reuse (--elab-only / --sim-only / --tag) ----------------------
# The default one-shot path above runs xvlog + xelab + xsim on every
# invocation.  That is the right default for a single run, but a regression
# sweep re-pays the ~5 s compile and ~7 s elaborate for every program even
# though the design and its generics never change across the sweep; only the
# +PROG plusarg does.  Measured on this machine: ~13 s of the ~15 s spent per
# program was recompilation.
#
#   --elab-only   run xvlog + xelab, build the snapshot, exit 0.  No xsim, so
#                 no PASS line is expected and the PASS/FAIL check is skipped.
#   --sim-only    skip xvlog + xelab and run xsim against an already-built
#                 snapshot (errors out if the snapshot is absent).
#   --tag TAG     suffix the snapshot name with _TAG.  Two elaborations that
#                 differ only in their -g generics (e.g. FORWARDING=0 vs 1)
#                 must not share a snapshot, so the batch caller passes a tag
#                 derived from the generics.  Default: no suffix, i.e. exactly
#                 the historical snapshot name <tb>_snap.
#
# Neither flag changes what the simulator does; --elab-only + N x --sim-only
# is byte-for-byte the same set of xsim runs as N one-shot invocations, just
# with the compile hoisted out of the loop.  tools/run_tests.py uses this
# path; every other caller gets the unchanged one-shot behaviour.
#
# Vivado bin dir is overridable via $VIVADO_BIN (default matches CLAUDE.md).
#
# --- Why this script mirrors rtl/tb/asm into an ASCII-only shadow dir -------
# The Vivado xvlog/xelab/xsim binaries on this machine use legacy ANSI Win32
# calls internally: they fail to create or open files whenever their current
# working directory contains a character outside the system codepage. This
# repo's path contains Thai characters ("เอกสาร"), which triggers exactly
# that failure (verified empirically: xvlog cannot even create its own
# xsim.dir when cwd is under the repo root).
#
# Workaround: every xvlog/xelab/xsim invocation runs with CWD set to an
# ASCII-only "shadow" directory under %LOCALAPPDATA%. That shadow work dir
# contains NTFS junctions named rtl/, tb/, asm/ pointing back at this repo's
# real directories (junctions are transparent at the filesystem level and do
# not copy any data), so relative references like $readmemh("asm/prog.hex")
# resolve exactly as they would with CWD = repo root. Junctions are created
# via PowerShell (Unicode-safe) the first time a given testbench's work dir
# is used. sim.log (and the .wdb if --wave was given) are copied back into
# the repo's sim/work/<tb>/ afterward, so nothing about the *outputs* differs
# from a machine whose path is plain ASCII — only the intermediate xsim.dir/
# clutter lives outside the repo instead of inside it (which is strictly
# better than the git-ignored default).  Any *.trace files a testbench writes
# into that shadow dir (tb_program writes ./rtl.trace) are copied back too.
# -----------------------------------------------------------------------------

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VIVADO_BIN="${VIVADO_BIN:-/d/AMDDesigntools/2026.1/Vivado/bin}"

usage() {
    echo "Usage: $0 <tb_name> [-g NAME=VALUE ...] [--plusarg +X=Y ...] [--wave] [--tag TAG] [--elab-only|--sim-only]" >&2
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

TB="$1"
shift

GENERICS=()
PLUSARGS=()
WAVE=0
TAG=""
DO_ELAB=1
DO_SIM=1

while [ $# -gt 0 ]; do
    case "$1" in
        -g)
            if [ $# -lt 2 ]; then echo "ERROR: -g requires NAME=VALUE" >&2; exit 1; fi
            GENERICS+=("$2")
            shift 2
            ;;
        --plusarg)
            if [ $# -lt 2 ]; then echo "ERROR: --plusarg requires +X=Y" >&2; exit 1; fi
            PLUSARGS+=("$2")
            shift 2
            ;;
        --wave)
            WAVE=1
            shift
            ;;
        --tag)
            if [ $# -lt 2 ]; then echo "ERROR: --tag requires a value" >&2; exit 1; fi
            TAG="$2"
            shift 2
            ;;
        --elab-only)
            DO_SIM=0
            shift
            ;;
        --sim-only)
            DO_ELAB=0
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ "$DO_ELAB" -eq 0 ] && [ "$DO_SIM" -eq 0 ]; then
    echo "ERROR: --elab-only and --sim-only are mutually exclusive" >&2
    exit 1
fi

SNAP="${TB}_snap"
if [ -n "$TAG" ]; then
    SNAP="${TB}_snap_${TAG}"
fi

TB_SRC_REPO="$REPO_ROOT/tb/$TB.v"
if [ ! -f "$TB_SRC_REPO" ]; then
    echo "ERROR: testbench source not found: $TB_SRC_REPO" >&2
    exit 1
fi

REPO_WORK="$REPO_ROOT/sim/work/$TB"
mkdir -p "$REPO_WORK"

SHADOW_BASE="$(cygpath -u "${LOCALAPPDATA:-$TEMP}")/pcpu_sim_shadow"
WORK="$SHADOW_BASE/sim/work/$TB"
mkdir -p "$WORK"

# Create rtl/tb/asm junctions inside WORK -> repo dirs, if not already present.
for d in rtl tb asm; do
    if [ ! -e "$WORK/$d" ]; then
        link_win="$(cygpath -w "$WORK/$d")"
        target_win="$(cygpath -w "$REPO_ROOT/$d")"
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
            "New-Item -ItemType Junction -Path '$link_win' -Target '$target_win' | Out-Null" \
            || { echo "ERROR: failed to create junction $WORK/$d -> $REPO_ROOT/$d" >&2; exit 1; }
    fi
done

LOG="$WORK/sim.log"
: > "$LOG"

cd "$WORK" || exit 1

shopt -s nullglob
RTL_FILES=(rtl/*.v)
shopt -u nullglob

if [ "$DO_ELAB" -eq 1 ]; then

echo "== xvlog ==" | tee -a "$LOG"
# NOTE: run.ps1 calls the .bat launchers (xvlog.bat) and works. The bash
# wrappers (xvlog, a shell script) drop the leading slash of path arguments
# before they reach the loader ("rtl/control.v" arrives as "ontrol.v"), and
# cmd.exe //c has the same problem. Routing the .bat through powershell.exe
# matches run.ps1 exactly and is verified working on this machine.
powershell.exe -NoProfile -NonInteractive -Command "& '$(cygpath -w "$VIVADO_BIN")\\xvlog.bat' --work work $(
    for f in "${RTL_FILES[@]}" "tb/$TB.v"; do printf " '%s'" "$f"; done
)" 2>&1 | tee -a "$LOG"
XVLOG_RC=${PIPESTATUS[0]}
if [ "$XVLOG_RC" -ne 0 ]; then
    echo "FAIL: $TB (xvlog exited $XVLOG_RC)" | tee -a "$LOG"
    cp -f "$LOG" "$REPO_WORK/sim.log"
    exit 1
fi

XELAB_ARGS=(-L work --snapshot "$SNAP" "$TB" --timescale 1ns/1ps)
# -generic_top NAME=VALUE and -testplusarg NAME=VALUE cannot be passed on the
# command line here: the xelab/xsim launchers are .bat wrappers, and cmd.exe
# splits an unquoted NAME=VALUE token on the '=' (the tool then reports
# "Expected a switch but found ..."), while quoting it turns the '=' into a
# space. Both tools accept "-f <file>" ("take command line options from a
# file"), which is immune to cmd.exe tokenisation, so the options go through
# a generated argument file instead.
if [ ${#GENERICS[@]} -gt 0 ]; then
    : > "xelab_args_${SNAP}.f"
    for g in "${GENERICS[@]}"; do
        printf -- '-generic_top "%s"\n' "$g" >> "xelab_args_${SNAP}.f"
    done
    XELAB_ARGS+=(-f "xelab_args_${SNAP}.f")
fi
if [ "$WAVE" -eq 1 ]; then
    XELAB_ARGS+=(--debug typical)
fi

echo "== xelab ==" | tee -a "$LOG"
powershell.exe -NoProfile -NonInteractive -Command "& '$(cygpath -w "$VIVADO_BIN")\\xelab.bat' $(
    for a in "${XELAB_ARGS[@]}"; do printf " '%s'" "$a"; done
)" 2>&1 | tee -a "$LOG"
XELAB_RC=${PIPESTATUS[0]}
if [ "$XELAB_RC" -ne 0 ]; then
    echo "FAIL: $TB (xelab exited $XELAB_RC)" | tee -a "$LOG"
    cp -f "$LOG" "$REPO_WORK/sim.log"
    exit 1
fi

fi  # end DO_ELAB

if [ "$DO_SIM" -eq 0 ]; then
    cp -f "$LOG" "$REPO_WORK/sim.log"
    echo "ELAB_ONLY_OK: snapshot $SNAP built in $WORK"
    exit 0
fi

if [ ! -d "$WORK/xsim.dir/$SNAP" ]; then
    echo "ERROR: snapshot '$SNAP' not found under $WORK/xsim.dir -- run once with --elab-only (same --tag and -g) first" >&2
    exit 1
fi

XSIM_ARGS=("$SNAP" --runall)
if [ ${#PLUSARGS[@]} -gt 0 ]; then
    : > "xsim_args_${SNAP}.f"
    for p in "${PLUSARGS[@]}"; do
        printf -- '-testplusarg "%s"\n' "${p#+}" >> "xsim_args_${SNAP}.f"
    done
    XSIM_ARGS+=(-f "xsim_args_${SNAP}.f")
fi
if [ "$WAVE" -eq 1 ]; then
    XSIM_ARGS+=(-wdb "${TB}.wdb")
fi

echo "== xsim ==" | tee -a "$LOG"
powershell.exe -NoProfile -NonInteractive -Command "& '$(cygpath -w "$VIVADO_BIN")\\xsim.bat' $(
    for a in "${XSIM_ARGS[@]}"; do printf " '%s'" "$a"; done
)" 2>&1 | tee -a "$LOG"
XSIM_RC=${PIPESTATUS[0]}

cp -f "$LOG" "$REPO_WORK/sim.log"
if [ "$WAVE" -eq 1 ] && [ -f "$WORK/${TB}.wdb" ]; then
    cp -f "$WORK/${TB}.wdb" "$REPO_WORK/${TB}.wdb"
fi

# Copy back any commit-trace files the testbench wrote into the shadow work dir
# (tb_program writes ./rtl.trace) so they are inspectable from the repo.
shopt -s nullglob
for tracefile in "$WORK"/*.trace; do
    cp -f "$tracefile" "$REPO_WORK/"
done
shopt -u nullglob

if [ "$XSIM_RC" -ne 0 ]; then
    echo "FAIL: $TB (xsim exited $XSIM_RC)" | tee -a "$REPO_WORK/sim.log"
    exit 1
fi

HAS_PASS=$(grep -c '^PASS' "$REPO_WORK/sim.log")
HAS_FAIL=$(grep -c '^FAIL' "$REPO_WORK/sim.log")

if [ "$HAS_FAIL" -gt 0 ]; then
    echo "run.sh: FAIL line(s) found in $REPO_WORK/sim.log" >&2
    exit 1
fi
if [ "$HAS_PASS" -eq 0 ]; then
    echo "run.sh: no PASS line found in $REPO_WORK/sim.log" >&2
    exit 1
fi

exit 0
