"""tools/rate/vivado.py -- the ONLY way the rating flow starts Vivado.

Refuses when a Vivado is already running on this box (presence by
/proc/PID/exe, never a count, never a command line: CLAUDE.md).  Runs under a
systemd-run cgroup cap and records memory.peak AND memory.swap.peak from
inside that cgroup, because a capped job's resident peak is the cap."""
import os, re, shlex, subprocess
import config

MARK = "unwrapped/lnx64.o/vivado"


def vivado_present():
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if MARK in os.readlink("/proc/%s/exe" % p):
                return True
        except OSError:
            continue
    return False


def run_batch(tcl, args, workdir, mem_high="24G", unit="rate-job"):
    if vivado_present():
        raise SystemExit("REFUSED: a Vivado is already running on this box (ONE per box)")
    os.makedirs(workdir, exist_ok=True)
    log = os.path.join(workdir, "vivado.log")
    wrap = os.path.join(workdir, "run.sh")
    argv = " ".join(shlex.quote(a) for a in args)
    # Written to a FILE and run as a file: a `bash -c` string handed to systemd-run
    # has its $vars expanded by systemd (CLAUDE.md, MEASURED 2026-09-21).
    with open(wrap, "w") as f:
        f.write("#!/usr/bin/env bash\n"
                "source %s/settings64.sh\n"
                "cd %s\n"
                "vivado -mode batch -nojournal -log %s -source %s -tclargs %s\n"
                "rc=$?\n"
                "cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)\n"
                "echo \"RATE_MEM peak $(cat $cg/memory.peak) swap_peak "
                "$(cat $cg/memory.swap.peak 2>/dev/null || echo NA) rc $rc\" >> %s\n"
                % (config.VIVADO_ROOT, workdir, log, tcl, argv, log))
    os.chmod(wrap, 0o755)
    maxb = "%dG" % (int(mem_high.rstrip("G")) + 2)
    r = subprocess.run(["systemd-run", "--user", "--wait", "--collect", "--unit=%s" % unit,
                        "-p", "MemoryHigh=%s" % mem_high, "-p", "MemoryMax=%s" % maxb, wrap])
    text = open(log).read() if os.path.exists(log) else ""
    m = re.search(r"^RATE_MEM peak (\d+) swap_peak (\S+) rc (\d+)\s*$", text, re.M)
    return {"log": text, "rc": int(m.group(3)) if m else r.returncode,
            "mem_peak": int(m.group(1)) if m else None,
            "swap_peak": int(m.group(2)) if m and m.group(2).isdigit() else None}
