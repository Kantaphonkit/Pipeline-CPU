#!/usr/bin/env python3
"""run_tests.py -- batch driver for tb/tb_program.v.

Runs one xsim simulation per assembly program found in the given directories
and prints a PASS/FAIL summary table with the per-program cycle / instruction
counts taken from the testbench's PERF line.

    python tools/run_tests.py --dir asm/insn --notrace
    python tools/run_tests.py --dir asm/insn --dir asm/hazard
    python tools/run_tests.py --dir asm/prog --fwd 0        # CPI comparison
    python tools/run_tests.py --dir asm/prog --irq-at 200,500   # interrupts
    python tools/run_tests.py --dir asm/prog --bht 0        # predictor off

A program is a `<name>.s` file; the testbench is invoked with
`+PROG=<dir>/<name>` and reads `<name>.hex`, `<name>.regs`,
`<name>.data.hex` (optional) and `<name>.trace` (unless --notrace) next to it.
Programs whose `.hex` or `.regs` fixture is missing are reported as SKIP and do
not fail the run -- generate them first (tools/gen_fixtures.py).

`sim/run.sh` reuses a single work directory (`sim/work/tb_program/`), so the
simulations must run one at a time.

Compilation is hoisted out of that loop.  Every program in one invocation is
simulated with the same design and the same generics -- only the `+PROG`
plusarg differs -- so the programs are grouped by their (FORWARDING,
BHT_ENABLE) pair (a single group per invocation, since both come from the
command line) and `sim/run.sh --elab-only --tag <group>` builds one snapshot
up front; each program then runs `sim/run.sh --sim-only --tag <group>`, which
is an xsim launch and nothing else.  That turns ~15 s per program into ~2 s.
The simulations themselves are unchanged -- same snapshot, same plusargs, same
xsim command line -- so the PASS/FAIL verdicts and the PERF numbers are
identical.  Pass --no-batch to fall back to the historical one-shot path
(xvlog + xelab + xsim per program), e.g. to bisect a suspected snapshot-reuse
problem.

With --irq-at the external interrupt is driven and the commit trace is checked
against a reference generated on the fly rather than against the committed
`.trace` fixture -- see `run_irq_trace_check` for why that indirection is
needed.  The register check still uses the committed `.regs` fixture, which is
timing-independent by construction for the interrupt demo.

Exit code: 0 if every program that ran PASSed, 1 otherwise.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_bash():
    """Locate Git Bash.

    On Windows a bare `bash` on PATH is usually System32\bash.exe, the WSL
    launcher -- which cannot see the Vivado install or the Windows paths
    sim/run.sh depends on.  Prefer $BASH, then the Git for Windows install,
    and only then whatever `bash` resolves to.
    """
    env = os.environ.get("BASH")
    if env and os.path.isfile(env):
        return env
    candidates = [
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                     "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                     "Git", "usr", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)",
                                    r"C:\Program Files (x86)"),
                     "Git", "bin", "bash.exe"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    if os.name != "nt":
        return found or "bash"
    print("ERROR: cannot find Git Bash; set $BASH to its bash.exe",
          file=sys.stderr)
    sys.exit(2)


BASH = find_bash()

PERF_RE = re.compile(
    r"^PERF cycles=(\d+) insns=(\d+) lu_stalls=(\d+) flushes=(\d+) "
    r"bht_pred=(\d+) bht_miss=(\d+)\s*$", re.M)
CPI_RE = re.compile(r"^CPI_x1000=(\d+)\s*$", re.M)
PASS_RE = re.compile(r"^PASS: tb_program\b", re.M)
FAIL_RE = re.compile(r"^FAIL: tb_program (.*)$", re.M)
FAIL_ANY_RE = re.compile(r"^FAIL:(.*)$", re.M)
IRQ_TAKEN_RE = re.compile(r"^IRQ_TAKEN retire_index=(\d+) ", re.M)

RTL_TRACE = os.path.join("sim", "work", "tb_program", "rtl.trace")

TB = "tb_program"


def batch_tag(fwd, bht):
    """Snapshot tag for a (FORWARDING, BHT_ENABLE) group.

    Two elaborations that differ in their generics must not share a snapshot,
    so the tag encodes them.  `d` means "not overridden" -- the RTL default,
    which is a different elaboration from an explicit -g of the same value
    only in bookkeeping, but keeping them distinct costs nothing and avoids
    surprising reuse.
    """
    return "f%s_b%s" % ("d" if fwd is None else fwd,
                        "d" if bht is None else bht)


def generic_args(fwd, bht):
    args = []
    if fwd is not None:
        args += ["-g", "FORWARDING=%d" % fwd]
    if bht is not None:
        args += ["-g", "BHT_ENABLE=%d" % bht]
    return args


def build_snapshot(fwd, bht, verbose):
    """xvlog + xelab once for a (fwd, bht) group. Returns True on success."""
    tag = batch_tag(fwd, bht)
    cmd = ([BASH, "sim/run.sh", TB, "--elab-only", "--tag", tag]
           + generic_args(fwd, bht))
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=REPO_ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace")
    if verbose:
        print(out)
    if proc.returncode != 0:
        print("ERROR: elaboration failed for group %s (rc=%d)"
              % (tag, proc.returncode), file=sys.stderr)
        for line in out.splitlines():
            if ("ERROR" in line or line.startswith("FAIL")
                    or "Error" in line):
                print("  %s" % line, file=sys.stderr)
        return False
    print("elaborated snapshot %s_snap_%s in %.1f s (compile hoisted out of "
          "the per-program loop)" % (TB, tag, time.time() - t0))
    return True


def read_trace(path):
    """Read a commit trace as a list of lines with line endings normalised.

    xsim's $fwrite opens files in text mode on Windows, so the RTL trace comes
    out CRLF-terminated while iss.py writes LF.  The content is identical; only
    the terminator differs, so both sides are normalised before comparing.
    """
    with io.open(path, "r", encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\r\n") for ln in fh]


def run_irq_trace_check(base, retire_indices, out_dir):
    """Diff the RTL trace against an ISS trace aligned to the RTL's interrupts.

    iss.py's `--irq-after N` traps at the boundary after N instructions have
    retired.  The RTL's N is not knowable in advance -- it depends on how many
    instructions happened to be in MEM and WB when the level arrived -- so
    tb_program measures it (the number of trace lines written before the first
    instruction at mtvec retires) and prints it as `IRQ_TAKEN retire_index=`.
    Feeding those numbers back to the ISS produces the trace the RTL should
    have produced, and the two are then compared byte for byte.

    Returns (n_diffs, [description lines]).
    """
    if not os.path.isfile(os.path.join(REPO_ROOT, RTL_TRACE)):
        return 1, ["no rtl.trace produced by the simulation"]

    ref = os.path.join(out_dir, os.path.basename(base) + ".iss.trace")
    cmd = [sys.executable, os.path.join("tools", "iss.py"), base + ".hex",
           "--trace", ref, "--max-insns", "200000"]
    data = base + ".data.hex"
    if os.path.isfile(os.path.join(REPO_ROOT, data)):
        cmd += ["--data", data]
    for k in retire_indices:
        cmd += ["--irq-after", str(k)]
    proc = subprocess.run(cmd, cwd=REPO_ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        return 1, ["iss.py exited %d: %s" % (
            proc.returncode,
            proc.stdout.decode("utf-8", "replace").strip().splitlines()[-1:])]

    rtl = read_trace(os.path.join(REPO_ROOT, RTL_TRACE))
    iss = read_trace(os.path.join(REPO_ROOT, ref) if not os.path.isabs(ref)
                     else ref)

    msgs = []
    n = 0
    for i in range(max(len(rtl), len(iss))):
        a = rtl[i] if i < len(rtl) else "<eof>"
        b = iss[i] if i < len(iss) else "<eof>"
        if a != b:
            n += 1
            if n <= 10:
                msgs.append("TRACEDIFF line %d: rtl=%s iss=%s" % (i + 1, a, b))
    if len(rtl) != len(iss):
        msgs.append("TRACE: line-count mismatch rtl=%d iss=%d"
                    % (len(rtl), len(iss)))
    if n:
        msgs.append("TRACE: %d differing line(s) over %d compared lines"
                    % (n, max(len(rtl), len(iss))))
    return n, msgs


def find_programs(dirs):
    """Return [(base_path_without_ext, label)] for every .s in `dirs`."""
    progs = []
    for d in dirs:
        full = os.path.join(REPO_ROOT, d)
        if not os.path.isdir(full):
            print("WARNING: no such directory: %s" % d, file=sys.stderr)
            continue
        for name in sorted(os.listdir(full)):
            if not name.endswith(".s"):
                continue
            base = name[:-2]
            progs.append(("%s/%s" % (d.replace("\\", "/").rstrip("/"), base),
                          "%s/%s" % (os.path.basename(d.rstrip("/\\")), base)))
    return progs


def run_one(prog, notrace, fwd, bht, maxcyc, verbose, irq_at=None,
            out_dir=None, batch=True):
    cmd = [BASH, "sim/run.sh", TB, "--plusarg", "+PROG=%s" % prog]
    if batch:
        cmd += ["--sim-only", "--tag", batch_tag(fwd, bht)]
    # With interrupts the in-testbench trace comparison is bypassed: the
    # committed .trace fixture is aligned to the reference model's interrupt
    # schedule, not the RTL's, so the diff is done here instead against a
    # freshly generated, RTL-aligned reference.
    if notrace or irq_at:
        cmd += ["--plusarg", "+NOTRACE"]
    if irq_at:
        for i, c in enumerate(irq_at[:3]):
            cmd += ["--plusarg", "+IRQ_AT%d=%d" % (i + 1, c)]
    if maxcyc is not None:
        cmd += ["--plusarg", "+MAXCYC=%d" % maxcyc]
    if not batch:
        # One-shot path: the generics go to xelab on this very invocation.
        # In batch mode they were already baked into the shared snapshot by
        # build_snapshot(), and passing them again would be ignored at best.
        cmd += generic_args(fwd, bht)

    proc = subprocess.run(cmd, cwd=REPO_ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace")
    if verbose:
        print(out)

    perf = PERF_RE.search(out)
    cpi = CPI_RE.search(out)
    fail = FAIL_RE.search(out)
    if fail is None:
        fail = FAIL_ANY_RE.search(out)
    result = {
        "prog": prog,
        "rc": proc.returncode,
        "passed": bool(PASS_RE.search(out)) and proc.returncode == 0,
        "reason": (fail.group(1).strip() if fail else ""),
        "cycles": int(perf.group(1)) if perf else 0,
        "insns": int(perf.group(2)) if perf else 0,
        "lu_stalls": int(perf.group(3)) if perf else 0,
        "flushes": int(perf.group(4)) if perf else 0,
        "bht_pred": int(perf.group(5)) if perf else 0,
        "bht_miss": int(perf.group(6)) if perf else 0,
        "cpi_x1000": int(cpi.group(1)) if cpi else 0,
        "irq_taken": len(IRQ_TAKEN_RE.findall(out)),
        "log": out,
    }

    if irq_at:
        ks = [int(m) for m in IRQ_TAKEN_RE.findall(out)]
        ndiff, msgs = run_irq_trace_check(prog, ks, out_dir or REPO_ROOT)
        result["log"] = out + "\n" + "\n".join(msgs)
        if ndiff and result["passed"]:
            result["passed"] = False
            result["reason"] = "%d trace line mismatch(es) vs ISS(irq-after %s)" % (
                ndiff, ",".join(str(k) for k in ks) or "none")
        if verbose:
            for m in msgs:
                print(m)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", action="append", dest="dirs", metavar="DIR",
                    help="directory of .s programs (repeatable); "
                         "default asm/insn")
    ap.add_argument("--notrace", action="store_true",
                    help="pass +NOTRACE (skip the commit-trace comparison)")
    ap.add_argument("--fwd", type=int, choices=(0, 1), default=None,
                    help="override the FORWARDING parameter")
    ap.add_argument("--bht", type=int, choices=(0, 1), default=None,
                    help="override the BHT_ENABLE parameter")
    ap.add_argument("--maxcyc", type=int, default=None,
                    help="override the testbench cycle budget")
    ap.add_argument("--irq-at", default=None, metavar="C1[,C2[,C3]]",
                    help="drive the external interrupt at these cycle numbers "
                         "(after reset release) and check the commit trace "
                         "against an ISS run aligned to the RTL's own "
                         "interrupt points")
    ap.add_argument("--only", default=None, metavar="SUBSTR",
                    help="only run programs whose path contains SUBSTR")
    ap.add_argument("--no-batch", action="store_true",
                    help="do not reuse one elaborated snapshot across the "
                         "run; recompile per program (the pre-2026-09-07 "
                         "behaviour, kept as an escape hatch)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="echo each simulation log")
    args = ap.parse_args()

    irq_at = None
    if args.irq_at:
        try:
            irq_at = [int(x, 0) for x in args.irq_at.split(",") if x.strip()]
        except ValueError:
            print("ERROR: --irq-at wants a comma-separated list of cycle "
                  "numbers", file=sys.stderr)
            return 1
        if len(irq_at) > 3:
            print("ERROR: --irq-at supports at most 3 cycles "
                  "(tb_program has +IRQ_AT1..3)", file=sys.stderr)
            return 1

    dirs = args.dirs or ["asm/insn"]
    progs = find_programs(dirs)
    if args.only:
        progs = [p for p in progs if args.only in p[0]]
    if not progs:
        print("ERROR: no .s programs found in: %s" % ", ".join(dirs),
              file=sys.stderr)
        return 1

    batch = not args.no_batch
    if batch and not build_snapshot(args.fwd, args.bht, args.verbose):
        return 1

    results = []
    skipped = []
    t0 = time.time()

    for base, _label in progs:
        hexf = os.path.join(REPO_ROOT, base + ".hex")
        regsf = os.path.join(REPO_ROOT, base + ".regs")
        missing = [os.path.basename(f) for f in (hexf, regsf)
                   if not os.path.isfile(f)]
        if not args.notrace and not irq_at and not os.path.isfile(
                os.path.join(REPO_ROOT, base + ".trace")):
            missing.append(os.path.basename(base) + ".trace")
        if missing:
            skipped.append((base, "missing " + ", ".join(missing)))
            print("SKIP %-28s (%s)" % (base, "missing " + ", ".join(missing)))
            continue

        r = run_one(base, args.notrace, args.fwd, args.bht, args.maxcyc,
                    args.verbose, irq_at=irq_at,
                    out_dir=os.path.join(REPO_ROOT, "sim", "work",
                                         "tb_program"),
                    batch=batch)
        results.append(r)
        print("%-4s %-28s cycles=%-7d insns=%-6d %s" % (
            "PASS" if r["passed"] else "FAIL", base, r["cycles"], r["insns"],
            "" if r["passed"] else "<- " + (r["reason"] or "no PASS line")))
        if not r["passed"] and not args.verbose:
            for line in r["log"].splitlines():
                if (line.startswith("REGDIFF") or line.startswith("TRACEDIFF")
                        or line.startswith("ERROR") or line.startswith("TRACE:")
                        or line.startswith("IRQ_TAKEN")
                        or line.startswith("    rtl =")
                        or line.startswith("    iss =")):
                    print("       %s" % line)

    elapsed = time.time() - t0
    npass = sum(1 for r in results if r["passed"])
    nfail = len(results) - npass

    print("")
    print("=" * 96)
    print("%-30s %6s %8s %8s %7s %7s %9s %6s %6s %5s" % (
        "program", "result", "cycles", "insns", "stalls", "flush",
        "CPI_x1000", "bpred", "bmiss", "acc%"))
    print("-" * 96)
    for r in results:
        acc = ("%5.1f" % (100.0 * (r["bht_pred"] - r["bht_miss"])
                          / r["bht_pred"])) if r["bht_pred"] else "    -"
        print("%-30s %6s %8d %8d %7d %7d %9d %6d %6d %s" % (
            r["prog"], "PASS" if r["passed"] else "FAIL", r["cycles"],
            r["insns"], r["lu_stalls"], r["flushes"], r["cpi_x1000"],
            r["bht_pred"], r["bht_miss"], acc))
    print("-" * 96)
    tot_cyc = sum(r["cycles"] for r in results)
    tot_ins = sum(r["insns"] for r in results)
    agg = (tot_cyc * 1000 // tot_ins) if tot_ins else 0
    tot_bp = sum(r["bht_pred"] for r in results)
    tot_bm = sum(r["bht_miss"] for r in results)
    tot_acc = ("%5.1f" % (100.0 * (tot_bp - tot_bm) / tot_bp)) if tot_bp else "    -"
    print("%-30s %6s %8d %8d %7d %7d %9d %6d %6d %s" % (
        "TOTAL (%d programs)" % len(results), "", tot_cyc, tot_ins,
        sum(r["lu_stalls"] for r in results),
        sum(r["flushes"] for r in results), agg, tot_bp, tot_bm, tot_acc))
    print("=" * 96)
    print("%d passed, %d failed, %d skipped, %.1f s" % (
        npass, nfail, len(skipped), elapsed))
    if nfail:
        print("failing programs: %s" % ", ".join(
            r["prog"] for r in results if not r["passed"]))

    return 1 if (nfail or not results) else 0


if __name__ == "__main__":
    sys.exit(main())
