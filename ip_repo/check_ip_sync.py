#!/usr/bin/env python3
"""ip_repo/*/src/*.vhd must be the bytes of rtl/*.vhd.  Nothing else checks it.

IPREPO-DRIFT.  Three packaged IPs under ip_repo/ carry their own copies of the
RTL, imported by `ipx::package_project -import_files`.  Those copies are
OUTPUTS: the source of truth is rtl/.  MEASURED 2026-08-29 by TRACK CLOG2TOP
and confirmed here, nothing in this repository ever re-runs the packagers --
no gate row, no build script, and sim/regress.sh did not mention ip_repo at
all.  TRACK CLOG2's note that "the next packaging run fixes them" described a
run that does not exist.  So rtl/util_pkg.vhd gained a corrected clog2
(209d69e) and the copies kept the overflowing doubling loop, silently.

WHY THIS CHECKER AND NOT "REGENERATE AND DIFF" IN THE GATE.  Both were on the
table and they are not equivalent.  Three measurements decided it:

  1. MEASURED: `git grep ip_repo` over every .tcl, .sh and .py in this tree
     returns the packaging script's own comment and nothing else.  There is no
     `set_property ip_repo_paths` anywhere.  NOTHING IN THIS REPOSITORY
     CONSUMES ip_repo/.  So the artefact being protected is a published
     package, not a live build input, and paying a Vivado invocation per gate
     run to protect it is the wrong trade.

  2. MEASURED: repackaging mac_axi with no RTL change at all still rewrites
     component.xml -- two `viewChecksum` values and `coreCreationDateTime`.  A
     "regenerate and diff" gate would therefore report a diff on EVERY run,
     from ipx metadata rather than from drift.  To make it useful you would
     have to narrow the diff to src/*.vhd, which is exactly what this script
     does, minus Vivado.

  3. All three packagers begin `file delete -force <ipdir>`.  A gate that
     regenerates can DESTROY the artefact it is checking if it is interrupted.
     A gate must not be able to damage what it inspects.

THE HONEST WEAKNESS, stated rather than buried: this checker compares outputs
to sources and cannot see a packaging script that is itself wrong.  Rules
UNLISTED and NOSCRIPT below narrow that gap without Vivado -- they refuse a
packaged file that no script names, and an IP directory that no script targets
-- but they do not close it.  MEASURED instance found while regenerating for
this commit and NOT catchable here: hw/package_mac_axi.tcl and
hw/package_matvec_engine.tcl both END IN AN ERROR, `Unknown property
'CONFIG.ASSOCIATED_BUSIF' on bus_interface`, after ipx::save_core has already
run.  The IP is written correctly and the script exits non-zero, so a caller
that checked the exit status would think packaging had failed.  Those two
files are not this track's to edit; the defect is recorded in
docs/debugging/2026-08-29_noguard-three-guards.md.

Usage:
    python3 ip_repo/check_ip_sync.py [--repo ROOT]
    python3 ip_repo/check_ip_sync.py --selftest
"""

import os
import re
import sys

RULES = ("STALE", "NOSRC", "NOSCRIPT", "UNLISTED")

# Where the packaging scripts live.  Discovered by CONTENT, not hardcoded per
# IP: each script is matched to the IP directory it names, so renaming an IP
# without renaming it in the script lands as NOSCRIPT rather than as silence.
SCRIPT_GLOBS = ("ip_repo", "hw")

_VHD = re.compile(r"([A-Za-z0-9_]+)\.vhd")
_IPDIR = re.compile(r"ip_repo/([A-Za-z0-9_]+_[0-9]+_[0-9]+)")


def _packagers(repo):
    """Map ip_repo subdirectory name -> (script path, set of listed basenames).

    The basename set is deliberately crude -- every `<name>.vhd` token in the
    script -- because the alternative is parsing Tcl.  It over-approximates,
    which is the safe direction for the UNLISTED rule: it can miss a file the
    script does not really add, and it cannot invent one.
    """
    out = {}
    for sub in SCRIPT_GLOBS:
        d = os.path.join(repo, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".tcl"):
                continue
            path = os.path.join(d, fn)
            try:
                src = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if "ipx::package_project" not in src:
                continue
            listed = set(_VHD.findall(src))
            for ipname in set(_IPDIR.findall(src)):
                out[ipname] = (os.path.relpath(path, repo), listed)
    return out


def check(repo, enabled=RULES):
    """Return (findings, stats).  A finding is (rule, path, detail)."""
    findings = []
    iproot = os.path.join(repo, "ip_repo")
    pkg = _packagers(repo)
    n_files = n_ips = 0
    if not os.path.isdir(iproot):
        return [("VOID", "ip_repo", "no ip_repo/ directory under %s" % repo)], \
               {"ips": 0, "files": 0}

    for ipname in sorted(os.listdir(iproot)):
        srcdir = os.path.join(iproot, ipname, "src")
        if not os.path.isdir(srcdir):
            continue
        n_ips += 1
        if "NOSCRIPT" in enabled and ipname not in pkg:
            findings.append(("NOSCRIPT", "ip_repo/%s" % ipname,
                             "no script under %s runs ipx::package_project "
                             "into this directory, so nothing in the tree can "
                             "regenerate it from rtl/"
                             % "/, ".join(SCRIPT_GLOBS)))
        listed = pkg.get(ipname, (None, set()))[1]
        for fn in sorted(os.listdir(srcdir)):
            if not fn.endswith(".vhd"):
                continue
            n_files += 1
            rel = "ip_repo/%s/src/%s" % (ipname, fn)
            ipf = os.path.join(srcdir, fn)
            rtlf = os.path.join(repo, "rtl", fn)
            if not os.path.exists(rtlf):
                if "NOSRC" in enabled:
                    findings.append(("NOSRC", rel,
                                     "there is no rtl/%s, so this copy has no "
                                     "source of truth and no packaging run "
                                     "can reproduce it" % fn))
                continue
            if "STALE" in enabled:
                a = open(ipf, "rb").read()
                b = open(rtlf, "rb").read()
                if a != b:
                    findings.append(("STALE", rel,
                                     "differs from rtl/%s (%d vs %d bytes). "
                                     "Do NOT hand-edit this copy: "
                                     "component.xml carries viewChecksum "
                                     "values over it. Re-run the packager."
                                     % (fn, len(a), len(b))))
            if "UNLISTED" in enabled and ipname in pkg and \
                    fn[:-4] not in listed:
                findings.append(("UNLISTED", rel,
                                 "%s does not name this file, so a packaging "
                                 "run would not refresh it"
                                 % pkg[ipname][0]))
    return findings, {"ips": n_ips, "files": n_files}


def _report(repo, enabled=RULES, quiet=False):
    findings, stats = check(repo, enabled)
    if not quiet:
        for rule, path, detail in findings:
            print("IPSYNC %-8s %s: %s" % (rule, path, detail))
        print("IPSYNC: %d IP(s), %d packaged .vhd, %d finding(s) [rules: %s]"
              % (stats["ips"], stats["files"], len(findings),
                 ",".join(enabled) if enabled else "none"))
    return findings, stats


# ---------------------------------------------------------------------------
# TEETH.  Every rule is driven on a synthetic tree, and every one is run again
# with the rules DISABLED as the attribution control: a finding that also
# appears with no rules enabled was produced by the harness, not by the check.
# Rows that must NOT fire are named and reported too -- they are what measures
# the resolution floor.

def _mktree(root, ip_files, rtl_files, script=None, ipname="demo_1_0"):
    os.makedirs(os.path.join(root, "rtl"), exist_ok=True)
    os.makedirs(os.path.join(root, "ip_repo", ipname, "src"), exist_ok=True)
    for name, body in rtl_files.items():
        open(os.path.join(root, "rtl", name), "w").write(body)
    for name, body in ip_files.items():
        open(os.path.join(root, "ip_repo", ipname, "src", name), "w").write(body)
    if script is not None:
        open(os.path.join(root, "ip_repo", "pkg.tcl"), "w").write(script)


def selftest():
    import shutil
    import tempfile

    GOOD_SCRIPT = ("ipx::package_project -root_dir $llama/ip_repo/demo_1_0 "
                   "-import_files\nadd_files [list $r/a.vhd $r/b.vhd]\n")

    def row_clean(root):
        _mktree(root, {"a.vhd": "X\n"}, {"a.vhd": "X\n"}, GOOD_SCRIPT)

    def row_stale(root):
        _mktree(root, {"a.vhd": "OLD\n"}, {"a.vhd": "NEW\n"}, GOOD_SCRIPT)

    def row_nosrc(root):
        _mktree(root, {"a.vhd": "X\n", "ghost.vhd": "X\n"},
                {"a.vhd": "X\n"}, GOOD_SCRIPT)

    def row_noscript(root):
        _mktree(root, {"a.vhd": "X\n"}, {"a.vhd": "X\n"}, None)

    def row_unlisted(root):
        _mktree(root, {"a.vhd": "X\n", "b.vhd": "X\n", "c.vhd": "X\n"},
                {"a.vhd": "X\n", "b.vhd": "X\n", "c.vhd": "X\n"}, GOOD_SCRIPT)

    def row_whitespace(root):
        # MUST NOT FIRE.  A byte comparison is the whole check, so a row that
        # differs only in trailing whitespace SHOULD be caught -- this row is
        # here to state that plainly, not to excuse it.
        _mktree(root, {"a.vhd": "X\n"}, {"a.vhd": "X \n"}, GOOD_SCRIPT)

    def row_nonvhd(root):
        # MUST NOT FIRE.  Non-.vhd files in src/ (xgui, xml) are not sources.
        _mktree(root, {"a.vhd": "X\n", "notes.txt": "anything"},
                {"a.vhd": "X\n"}, GOOD_SCRIPT)

    def row_renamed_ip(root):
        # The script still names demo_1_0; the directory was renamed.
        _mktree(root, {"a.vhd": "X\n"}, {"a.vhd": "X\n"}, GOOD_SCRIPT,
                ipname="renamed_2_0")

    ROWS = [
        ("CLEAN", row_clean, None),
        ("STALE", row_stale, "STALE"),
        ("NOSRC", row_nosrc, "NOSRC"),
        ("NOSCRIPT", row_noscript, "NOSCRIPT"),
        ("UNLISTED", row_unlisted, "UNLISTED"),
        ("RENAMED", row_renamed_ip, "NOSCRIPT"),
        ("WSPACE", row_whitespace, "STALE"),
        ("NONVHD", row_nonvhd, None),
    ]
    names = [r[0] for r in ROWS]
    if len(set(names)) != len(names):
        sys.exit("SELFTEST ABORT: duplicate row name in the table. A "
                 "duplicate is silent -- one row is never run and another "
                 "runs twice, and the table looks full either way.")
    # Teeth on that gate itself.
    _dupe = ["x", "x"]
    if len(set(_dupe)) == len(_dupe):
        sys.exit("SELFTEST ABORT: the duplicate-name gate cannot fire.")

    print("row        expect      rules-on   rules-off  attribution")
    print("-" * 66)
    bad = []
    alone = 0
    for name, build, expect in ROWS:
        root = tempfile.mkdtemp(prefix="ipsync.")
        try:
            build(root)
            on, _ = check(root, RULES)
            off, _ = check(root, ())
            got = sorted({f[0] for f in on}) or ["-"]
            gotoff = sorted({f[0] for f in off}) or ["-"]
            if expect is None:
                ok = (got == ["-"])
                attr = "n/a (must not fire)"
            else:
                ok = (expect in got)
                if ok and expect not in gotoff:
                    attr, alone = "CHECK ALONE", alone + 1
                elif ok:
                    attr = "both"
                else:
                    attr = "NEITHER"
            if not ok:
                bad.append("%s: expected %s, got %s"
                           % (name, expect or "no finding", ",".join(got)))
            print("%-10s %-11s %-10s %-10s %s%s"
                  % (name, expect or "no finding", ",".join(got),
                     ",".join(gotoff), attr, "" if ok else "   <== WRONG"))
        finally:
            shutil.rmtree(root, ignore_errors=True)

    # VOID: a tree with no ip_repo/ at all must be VOID, never a pass.
    root = tempfile.mkdtemp(prefix="ipsync.")
    try:
        vf, _ = check(root, RULES)
        vd = "VOID" if any(f[0] == "VOID" for f in vf) else "PASSED"
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("%-10s %-11s %-10s %-10s %s%s"
          % ("VD", "VOID", vd, "-", "no ip_repo/ present",
             "" if vd == "VOID" else "   <== WRONG"))
    if vd != "VOID":
        bad.append("VD: a missing ip_repo/ scored %s, not VOID" % vd)

    print("-" * 66)
    print("CHECK ALONE=%d" % alone)
    if bad:
        for b in bad:
            print("FAIL " + b)
        sys.exit("SELFTEST FAIL")
    if alone == 0:
        sys.exit("SELFTEST FAIL: no rule earned a finding of its own.")
    print("SELFTEST PASS")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if "--repo" in argv:
        repo = argv[argv.index("--repo") + 1]
    findings, _ = _report(repo)
    if findings:
        print("IPSYNC: FAIL -- ip_repo/ is not the bytes of rtl/. Re-run the "
              "packagers (they need Vivado); do NOT hand-edit the copies.")
        return 1
    print("IPSYNC: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
