# The box hung, and the dispatcher put it there

**Date:** 2026-08-30, hang at 01:24-01:25, recovered by power button ~06:27.
**Machine:** 31 GiB, 24 threads, Ubuntu 6.8.0-138.
**Cost:** a composed place-and-route past 90 minutes, the FPGA's configuration,
and about five hours of wall clock.

## The question, verbatim

The box hung hard enough that Oren had to hold the power button. What killed
it, was the FPGA or the `xdma` driver involved, and what should have prevented
it?

## The answer, up front

**Memory exhaustion turning into compaction thrashing.** Not an OOM kill --
an OOM kill is contained and survivable, and several happened earlier in the
day without incident. This was the kernel failing to make enough forward
progress to kill anything at all.

**Neither the FPGA nor `xdma` was involved.**

**The dispatcher caused it**, by running five concurrent tracks on a box whose
free memory it had already measured at zero.

## The evidence, raw

`journalctl -b -1`, the last thing the machine logged:

```
Aug 30 01:24:09 kernel: rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
Aug 30 01:24:09 kernel: rcu:   0-...0: (1 GPs behind) idle=0cdc/1/0x4000000000000000 softirq=19161704/19161705 fqs=24184
Aug 30 01:24:09 kernel: rcu:   cputime: 0 0 0   ==> 30001(ms)
Aug 30 01:24:10 kernel: watchdog: BUG: soft lockup - CPU#23 stuck for 23s! [kcompactd0:168]
Aug 30 01:24:14 kernel: watchdog: BUG: soft lockup - CPU#10 stuck for 23s! [usbip:3706463]
Aug 30 01:24:14 kernel: watchdog: BUG: soft lockup - CPU#8  stuck for 23s! [bash:3241525]
Aug 30 01:24:14 kernel: watchdog: BUG: soft lockup - CPU#19 stuck for 23s! [bash:3706405]
Aug 30 01:24:14 kernel: watchdog: BUG: soft lockup - CPU#22 stuck for 23s! [bash:3716975]
Aug 30 01:24:34 kernel: watchdog: BUG: soft lockup - CPU#2  stuck for 78s! [llama-server:3656693]
Aug 30 01:24:38 kernel: watchdog: BUG: soft lockup - CPU#23 stuck for 49s! [kcompactd0:168]
Aug 30 01:25:06 kernel: watchdog: BUG: soft lockup - CPU#23 stuck for 75s! [kcompactd0:168]
```

Last line of the boot: `01:25:14`, mid-stack-dump. Nothing after.

**`kcompactd0` is the tell.** It is the kernel's memory-compaction daemon. It
being stuck for 75 s, with RCU stalls and nine CPUs in soft lockup, is a
machine spending all its time trying to assemble contiguous pages and failing.

The machine state I had measured myself twelve minutes earlier, at 01:08:

```
    PID     ELAPSED   RSS COMMAND
2244709       06:03 3985976 vivado
1596765    01:14:52 2300680 vivado
2434936       03:11 1469600 vivado
2438282       03:05  708412 vivado
2436674       03:07  604908 vivado
2436547       03:09  544036 vivado
              total  used  free  shared  buff/cache  available
Mem:             31    11     0       0          18         18
 01:08:16 up 1 day, 13:50,  load average: 6.03, 5.65, 6.47
```

Six Vivado processes, and `llama-server` holding 18 GiB that is not in that
list because it was resident below the cutoff shown.

## The procedure that produced the answer

1. **`uptime` and `git status` first**, before anything else, to establish what
   survived. 235 lines of uncommitted work from two stopped tracks were intact.
2. **Check the card, because a power-button reboot cuts PCIe slot power.**
   `lspci -nn | grep -i 10ee` returns nothing and `lsmod | grep xdma` shows the
   module unloaded. The FPGA is volatile-configured, so it presents no endpoint
   until reprogrammed. **This is expected, not damage.**
3. **`journalctl -b -1 -p err`** for the shape of the death.
4. **Rule the card in or out explicitly**, because a segfault had occurred in a
   DMA probe an hour earlier and it was a live suspect.

## Measured and REJECTED -- do not retry

* **"The `os.preadv` segfault in my DMA probe caused it."** REJECTED. The
  segfault was at ~01:12 in a Python process; `fk33ctl.py id` was run
  immediately afterwards and returned a correct magic word, proving link,
  config space, BAR placement, AXI-Lite clock and reset all healthy. The hang
  came twelve minutes later with no card involvement.
* **"`xdma` faulted."** REJECTED, and this one is a **measurement trap worth
  naming**: `journalctl -b -1 | grep -ci xdma` returns **258**, which looks
  damning. Every one of them is inside a `Modules linked in:` line, which every
  soft-lockup stack dump prints in full. **A grep count over a kernel log
  counts stack dumps, not events.** Read the surrounding line before believing
  a match.
* **"It was an OOM kill."** REJECTED as the proximate cause. There were real
  OOM kills that day -- `ghdl-mcode` twice at 16:48, 20.9 GiB anon-RSS each,
  both `CONSTRAINT_MEMCG` and therefore contained by `claude-tmux`'s cgroup.
  Those did no harm. The 01:25 event is the opposite: the kernel never got far
  enough to kill anything.
* **"Cap each agent's memory and the problem goes away."** REJECTED as the
  lesson. Each brief already carried the machine state and an instruction to
  check it. Every agent checked. See below.

## The actual mistake

Every brief said "check `df -h`, `free -g` and `uptime` first and report what
you measured", and every track did. **That is not a budget, it is a survey.**

An agent can see its own footprint and cannot see any other track's. Each one
looked, found room for itself, and was individually right. The dispatcher is
the only party that can see the sum, and it dispatched two further tracks after
measuring `0 free, 21 GiB swap in use, load 10.1` -- and after writing exactly
those numbers into both briefs as a warning.

**Writing the hazard into the brief felt like managing it. It is the opposite:
it is a record that the dispatcher knew and proceeded.**

The durable form of this is now in `CLAUDE.md` under "THE MEMORY BUDGET IS
GLOBAL, AND ONLY THE DISPATCHER CAN SEE IT", with the measured peaks that make
the arithmetic concrete: `pcieep` build 25.0 GiB, single OOC synthesis
11.9 GiB, `ghdl-mcode` 20.9 GiB, against ~13 GiB of headroom once
`llama-server` has taken its 18.

## Measurement traps hit

* **The 258 `xdma` grep hits**, above. The single most misleading number in the
  whole investigation, and it pointed at the one subsystem that had to be
  cleared before any card work could resume.
* **`free` showing "0 free" is a lagging indicator.** By then the box is living
  on the swapfile. `available` and swap-in-use are what move first, and at
  01:08 `available` still read 18, which reads as healthy and was not.
* **The load average understated it.** 6.03 on 24 threads looks like 25%
  utilisation. It was memory-bound, not CPU-bound, and load average says
  nothing about that until the stalls begin.

## Open, not yet answered

* **Whether the composed place-and-route can be re-run at all** under a
  one-Vivado-at-a-time rule, or whether it needs `llama-server` stopped. Its
  peak was never measured; it was killed at 90 minutes by the hang.
* **Whether `vm.swappiness=60` helped or hurt here.** It was raised from 10
  deliberately to avoid a different failure mode. This event is the opposite
  case and the interaction is not characterised.
* **The card has not been reprogrammed** as of this writing, and no card work
  can resume until it is.
