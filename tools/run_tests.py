#!/usr/bin/env python3
"""run_tests.py -- batch driver for tb/tb_program.v.

Runs one xsim simulation per assembly program found in the given directories
and prints a PASS/FAIL summary table with the per-program cycle / instruction
counts taken from the testbench's PERF line.

    python tools/run_tests.py --dir asm/insn --notrace
    python tools/run_tests.py --dir asm/insn --dir asm/hazard
    python tools/run_tests.py --dir asm/prog --fwd 0        # CPI comparison

A program is a `<name>.s` file; the testbench is invoked with
`+PROG=<dir>/<name>` and reads `<name>.hex`, `<name>.regs`,
`<name>.data.hex` (optional) and `<name>.trace` (unless --notrace) next to it.
Programs whose `.hex` or `.regs` fixture is missing are reported as SKIP and do
not fail the run -- generate them first (tools/gen_fixtures.py).

`sim/run.sh` reuses a single work directory (`sim/work/tb_program/`), so the
simulations must run one at a time; each xsim launch costs roughly 5-10 s.

Exit code: 0 if every program that ran PASSed, 1 otherwise.
"""

import argparse
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


def run_one(prog, notrace, fwd, bht, maxcyc, verbose):
    cmd = [BASH, "sim/run.sh", "tb_program", "--plusarg", "+PROG=%s" % prog]
    if notrace:
        cmd += ["--plusarg", "+NOTRACE"]
    if maxcyc is not None:
        cmd += ["--plusarg", "+MAXCYC=%d" % maxcyc]
    if fwd is not None:
        cmd += ["-g", "FORWARDING=%d" % fwd]
    if bht is not None:
        cmd += ["-g", "BHT_ENABLE=%d" % bht]

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
        "log": out,
    }
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
    ap.add_argument("--only", default=None, metavar="SUBSTR",
                    help="only run programs whose path contains SUBSTR")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="echo each simulation log")
    args = ap.parse_args()

    dirs = args.dirs or ["asm/insn"]
    progs = find_programs(dirs)
    if args.only:
        progs = [p for p in progs if args.only in p[0]]
    if not progs:
        print("ERROR: no .s programs found in: %s" % ", ".join(dirs),
              file=sys.stderr)
        return 1

    results = []
    skipped = []
    t0 = time.time()

    for base, _label in progs:
        hexf = os.path.join(REPO_ROOT, base + ".hex")
        regsf = os.path.join(REPO_ROOT, base + ".regs")
        missing = [os.path.basename(f) for f in (hexf, regsf)
                   if not os.path.isfile(f)]
        if not args.notrace and not os.path.isfile(
                os.path.join(REPO_ROOT, base + ".trace")):
            missing.append(os.path.basename(base) + ".trace")
        if missing:
            skipped.append((base, "missing " + ", ".join(missing)))
            print("SKIP %-28s (%s)" % (base, "missing " + ", ".join(missing)))
            continue

        r = run_one(base, args.notrace, args.fwd, args.bht, args.maxcyc,
                    args.verbose)
        results.append(r)
        print("%-4s %-28s cycles=%-7d insns=%-6d %s" % (
            "PASS" if r["passed"] else "FAIL", base, r["cycles"], r["insns"],
            "" if r["passed"] else "<- " + (r["reason"] or "no PASS line")))
        if not r["passed"] and not args.verbose:
            for line in r["log"].splitlines():
                if (line.startswith("REGDIFF") or line.startswith("TRACEDIFF")
                        or line.startswith("ERROR") or line.startswith("TRACE:")
                        or line.startswith("    rtl =")
                        or line.startswith("    iss =")):
                    print("       %s" % line)

    elapsed = time.time() - t0
    npass = sum(1 for r in results if r["passed"])
    nfail = len(results) - npass

    print("")
    print("=" * 96)
    print("%-34s %8s %8s %9s %8s %8s %9s" % (
        "program", "result", "cycles", "insns", "stalls", "flushes",
        "CPI_x1000"))
    print("-" * 96)
    for r in results:
        print("%-34s %8s %8d %9d %8d %8d %9d" % (
            r["prog"], "PASS" if r["passed"] else "FAIL", r["cycles"],
            r["insns"], r["lu_stalls"], r["flushes"], r["cpi_x1000"]))
    print("-" * 96)
    tot_cyc = sum(r["cycles"] for r in results)
    tot_ins = sum(r["insns"] for r in results)
    agg = (tot_cyc * 1000 // tot_ins) if tot_ins else 0
    print("%-34s %8s %8d %9d %8d %8d %9d" % (
        "TOTAL (%d programs)" % len(results), "", tot_cyc, tot_ins,
        sum(r["lu_stalls"] for r in results),
        sum(r["flushes"] for r in results), agg))
    print("=" * 96)
    print("%d passed, %d failed, %d skipped, %.1f s" % (
        npass, nfail, len(skipped), elapsed))
    if nfail:
        print("failing programs: %s" % ", ".join(
            r["prog"] for r in results if not r["passed"]))

    return 1 if (nfail or not results) else 0


if __name__ == "__main__":
    sys.exit(main())
