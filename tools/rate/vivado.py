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


BC250_ROOT = "/home/orencollaco/ratings"


def bc250_host():
    """The BC-250's address from the router's lease, never a hardcoded one (it is DHCP:
    CLAUDE.md, CORRECTION 2026-09-15)."""
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "labuser@192.0.2.1",
                        "grep -i cachyos /var/lib/misc/dnsmasq.leases"], capture_output=True, text=True)
    parts = r.stdout.split()
    if len(parts) < 3:
        raise SystemExit("BC-250 has no lease on the router; resolve it before dispatch (CLAUDE.md)")
    return parts[2]


def run_batch_bc250(tcl, args, workdir, mem_high="11G", unit="rate-job"):
    """Same contract as run_batch, on the BC-250. `workdir` is a LOCAL path; the remote work
    directory mirrors it under BC250_ROOT. Tree paths in `args` and the file list use the repo
    prefix, which is the sync destination on both boxes. The script goes through `bash -s` on
    stdin because the remote shell is fish (CLAUDE.md, MEASURED 2026-09-19)."""
    if int(mem_high.rstrip("G")) > 11:
        raise SystemExit("REFUSED: MemoryHigh above 11G on the BC-250 (CLAUDE.md: a 12G cap cost the box)")
    ip = bc250_host()
    host = "labuser@" + ip
    ssh = ["ssh", "-o", "BatchMode=yes", host]
    # Sync first, every time: a result against a stale tree is indistinguishable from a real one.
    subprocess.run(["bash", os.path.expanduser("~/GitHub/DevOps/bc250-sync-llama-vhdl.sh")], check=True,
                   cwd=config.REPO, env=dict(os.environ, HOST=host))
    rwd = BC250_ROOT + "/" + os.path.relpath(workdir, config.WORK_ROOT)
    subprocess.run(ssh + ["mkdir -p " + shlex.quote(rwd)], check=True)
    for f in ("rate_shell.vhd", "files.txt"):
        lp = os.path.join(workdir, f)
        if os.path.exists(lp):
            subprocess.run(["scp", "-q", "-o", "BatchMode=yes", lp, "%s:%s/%s" % (host, rwd, f)], check=True)
    rargs = [a.replace(workdir, rwd) for a in args]
    log = rwd + "/vivado.log"
    high = int(mem_high.rstrip("G")) * 1024 ** 3
    script = "\n".join([
        "set -u",
        "export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus",
        "for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue;"
        " case \"$e\" in *%s*) echo RATE_REFUSED_VIVADO_PRESENT; exit 1;; esac; done" % MARK,
        "sed -i 's#%s#%s#g' %s/files.txt" % (workdir, rwd, rwd),
        "cat > %s/run.sh <<'RUNEOF'" % rwd,
        "#!/usr/bin/env bash",
        "source %s/settings64.sh" % config.VIVADO_ROOT,
        "cd %s" % rwd,
        "vivado -mode batch -nojournal -log %s -source %s -tclargs %s"
        % (log, tcl, " ".join(shlex.quote(x) for x in rargs)),
        "rc=$?",
        "cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)",
        "echo \"RATE_MEM peak $(cat $cg/memory.peak) swap_peak $(cat $cg/memory.swap.peak 2>/dev/null || echo NA)"
        " rc $rc\" >> %s" % log,
        "RUNEOF",
        "chmod +x %s/run.sh" % rwd,
        "systemd-run --user --collect --unit=%s -p MemoryHigh=%s -p MemoryMax=%dG %s/run.sh"
        % (unit, mem_high, int(mem_high.rstrip("G")) + 1, rwd),
        "sleep 3",
        # The readback IS the guard: without it an uncapped Vivado on a 14 GB box is invisible.
        "got=$(systemctl --user show %s -p MemoryHigh --value)" % unit,
        "[ \"$got\" = \"%d\" ] || { echo RATE_REFUSED_CAP_NOT_APPLIED $got; systemctl --user stop %s; exit 1; }"
        % (high, unit),
        "echo RATE_CAP_OK $got",
        "while systemctl --user is-active --quiet %s; do sleep 20; done" % unit,
        "echo RATE_REMOTE_DONE",
    ]) + "\n"
    r = subprocess.run(ssh + ["bash -s"], input=script, text=True, capture_output=True)
    if not re.search(r"^RATE_CAP_OK ", r.stdout, re.M) or not re.search(r"^RATE_REMOTE_DONE$", r.stdout, re.M):
        raise SystemExit("BC-250 run did not complete:\n" + r.stdout + r.stderr)
    # rsync, not `scp -r host:dir/.` (MEASURED 2026-09-25: the SFTP-mode scp refuses that form).
    subprocess.run(["rsync", "-a", "-e", "ssh -o BatchMode=yes", "%s:%s/" % (host, rwd), workdir + "/"], check=True)
    # The remote finishing is a fact about the harness; the job's own sentinel is RATE_MEM here and
    # ^RATE_DONE in record.parse_log.
    text = open(os.path.join(workdir, "vivado.log")).read()
    m = re.search(r"^RATE_MEM peak (\d+) swap_peak (\S+) rc (\d+)\s*$", text, re.M)
    return {"log": text, "rc": int(m.group(3)) if m else 1,
            "mem_peak": int(m.group(1)) if m else None,
            "swap_peak": int(m.group(2)) if m and m.group(2).isdigit() else None}
