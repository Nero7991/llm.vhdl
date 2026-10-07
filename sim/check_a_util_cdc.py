#!/usr/bin/env python3
"""Structural CDC check for the utilisation counters in
rtl/matvec_int4_desc_axi.vhd (Jungle Cat engine composition, Task 1 fix
round 1, 2026-10-07).

WHY STRUCTURAL.  GHDL samples atomically, so a glitch on a combinational
signal feeding a synchroniser is invisible to every bench: the defect class
is "the synchroniser's input is not a flop", and only the text can show it.

Checks, each REFUSED with a reason:
  C1  under DUAL_CLK the window synchroniser `job_s` shifts in `u_job_r`,
      and in no arm `u_job_c` (the combinational decode).
  C2  `u_job_r` is assigned only inside a process clocked by s_axi_aclk.
  C3  the counter's read index comes from `u_sel_h`, never `u_sel`.
  C4  `u_sel_h` is assigned only inside a process clocked by s_axi_aclk.

Usage:  python3 sim/check_a_util_cdc.py [file]      exit 0 = PASS
        python3 sim/check_a_util_cdc.py --selftest  each mutant must REFUSE
"""
import re
import sys

DEFAULT = "rtl/matvec_int4_desc_axi.vhd"


def processes(txt):
    """(clock, body) per `name : process(clk)` ... `end process`."""
    out = []
    for m in re.finditer(r"^\s*\w+\s*:\s*process\s*\(([^)]*)\)(.*?)^\s*end process",
                         txt, re.M | re.S):
        out.append((m.group(1).strip(), m.group(2)))
    return out


def assigned_only_in(txt, sig, clk):
    pat = re.compile(r"\b%s\s*<=" % re.escape(sig))
    total = len(pat.findall(txt))
    inside = sum(len(pat.findall(b)) for c, b in processes(txt) if c == clk)
    return total > 0 and total == inside, total, inside


def check(txt):
    txt = re.sub(r"--[^\n]*", "", txt)     # comments say what code does not
    bad = []
    js = re.findall(r"job_s\s*<=\s*job_s\(0\)\s*&\s*(\w+)\s*;", txt)
    if not js or any(x != "u_job_r" for x in js):
        bad.append("C1 job_s shifts in %r, want only u_job_r" % js)
    ok, t, i = assigned_only_in(txt, "u_job_r", "s_axi_aclk")
    if not ok:
        bad.append("C2 u_job_r assigned %d times, %d inside s_axi_aclk "
                   "processes" % (t, i))
    idx = re.findall(r"rd_idx\s*=>\s*unsigned\((\w+)\(", txt)
    hi = re.findall(r"rd_hi\s*=>\s*(\w+)\(", txt)
    if not idx or any(x != "u_sel_h" for x in idx + hi):
        bad.append("C3 counter read index from %r / %r, want u_sel_h" % (idx, hi))
    ok, t, i = assigned_only_in(txt, "u_sel_h", "s_axi_aclk")
    if not ok:
        bad.append("C4 u_sel_h assigned %d times, %d inside s_axi_aclk "
                   "processes" % (t, i))
    return bad


MUTANTS = [
    ("K1 window synchroniser fed from the combinational decode",
     "job_s <= job_s(0) & u_job_r;", "job_s <= job_s(0) & u_job_c;"),
    ("K2 u_job_r made combinational",
     "      if st = S_WAIT then u_job_r <= '1'; else u_job_r <= '0'; end if;\n", ""),
    ("K3 counter reads the live u_sel",
     "rd_idx => unsigned(u_sel_h(7 downto 1)), rd_hi => u_sel_h(0),",
     "rd_idx => unsigned(u_sel(7 downto 1)), rd_hi => u_sel(0),"),
]


def main():
    args = sys.argv[1:]
    if args == ["--selftest"]:
        txt = open(DEFAULT).read()
        if check(txt):
            print("CHECK_A_UTIL_CDC SELFTEST: the clean file fails: %s" % check(txt))
            return 1
        nbad = 0
        for name, a, b in MUTANTS:
            if txt.count(a) < 1:
                print("SELFTEST %s: anchor not found" % name); nbad += 1; continue
            m = txt.replace(a, b)
            if name.startswith("K2"):
                m = m.replace("  u_job_c <= '1' when st = S_WAIT else '0';",
                              "  u_job_c <= '1' when st = S_WAIT else '0';\n"
                              "  u_job_r <= u_job_c;")
            r = check(m)
            print("SELFTEST %-55s %s" % (name, "REFUSED" if r else "SURVIVED"))
            if not r:
                nbad += 1
        print("CHECK_A_UTIL_CDC SELFTEST: %s" % ("PASS" if nbad == 0 else "FAIL"))
        return 1 if nbad else 0
    path = args[0] if args else DEFAULT
    bad = check(open(path).read())
    for b in bad:
        print("REFUSED " + b)
    print("CHECK_A_UTIL_CDC: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
