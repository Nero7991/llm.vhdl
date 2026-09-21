#!/usr/bin/env python3
"""tools/upstream_pin.py -- pin the content of a generator input that lives
OUTSIDE this repository.

WHY THIS EXISTS.

MEASURED 2026-09-20 (TRACK TCLOWNER, extended by TRACK UPPIN): two generators
in this tree read files from `~/GitHub/SQRL_FK33`, a third-party checkout that
is not in this repository, is not a submodule, and whose revision nothing here
records.

    hw/fk33/gen_firstlight.py:19   projects/fk33_example.tcl
    hw/fk33/gen_i2cprobe.py:42     projects/fk33_example.xdc

**The second of those is read on EVERY CARD BUILD.**  `hw/fk33/pcieep_build.sh`
line 84 runs `gen_i2cprobe.py`, which copies every upstream constraint line
verbatim into `hw/fk33/fk33_i2cprobe.xdc`; that is `gen_pcieep.py`'s `XDC_SRC`,
which produces `hw/fk33/fk33_pcieep.xdc`, which Vivado reads in place.  So the
pin assignments and clock constraints that go into the bitstream are sourced
from a file outside the repository, re-read fresh every time, at a revision
nothing records.

WHY THE GENERATORS' EXISTING GUARDS ARE NOT THIS GUARD.  Both already abort
loudly when a substitution anchor stops matching, and that is real: it covers
the handful of lines each generator REWRITES.  It says nothing about the other
four hundred.  MEASURED by TRACK UPPIN, with an attribution control:

    upstream mutated: CONFIG.USER_HBM_STACK {2} -> {1}   (one line, touching
    no substitution anchor and no exclude_bd_addr_seg call)

      gen_firstlight.py  ->  rc=0, prints its two normal lines, no warning,
                             and emits a build script whose HBM stack count
                             has silently changed.  difflines=4.
      control, same generator against the real upstream:  difflines=0.

A guard that only checks the lines you rewrite cannot see a change to the lines
you copy, and copying is what these generators mostly do.

WHAT THIS DOES INSTEAD.  It pins the SHA-256 of the whole input file and
refuses to run when it differs.  That converts an unpinned external dependency
into a recorded one: the expected hash, the upstream commit and the blob id
live in the generator's source, in THIS repository, under version control, so
`git log` finally answers "which upstream did this come from".

WHY THERE IS NO ENVIRONMENT-VARIABLE OVERRIDE, DELIBERATELY.  An override would
be one more piece of out-of-band input that changes what a generator emits,
which is the exact hazard `tools/genstamp.py` was written for.  When upstream
legitimately changes, the operator reads the diff and edits the constant, and
that edit lands in git as a dated, reviewable record of the revision bump.  The
friction is the feature: re-pinning is a decision, and it should look like one.
"""

import hashlib
import os
import sys


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def require(path, expect_sha256, generator, upstream):
    """Abort unless the file at `path` hashes to `expect_sha256`.

    `generator`  the script doing the reading, for the error message.
    `upstream`   a human string naming the pinned revision, e.g.
                 "SQRL_FK33 4242680 blob 157ea2dd".

    Absence and mismatch are reported as DIFFERENT failures, because they need
    different actions: a missing file means the checkout is not there, and a
    changed file means it is there and has moved.  Reporting both as "cannot
    read upstream" is the kind of merged error message that sends the next
    person down the wrong path.
    """
    if not os.path.exists(path):
        sys.exit(
            "%s: ABORT -- upstream input not found: %s\n"
            "  This generator reads a file OUTSIDE this repository.  Clone\n"
            "  https://github.com/d953i/SQRL_FK33.git to that path, at %s."
            % (generator, path, upstream))
    got = sha256_of(path)
    if got != expect_sha256:
        sys.exit(
            "%s: ABORT -- the upstream input has CHANGED.\n"
            "    file      %s\n"
            "    expected  %s  (%s)\n"
            "    observed  %s\n"
            "  This file is outside this repository and is copied almost\n"
            "  verbatim into generated output, so emitting against an\n"
            "  unreviewed version would silently change constraints or block\n"
            "  design configuration in a diff that looks like ordinary drift.\n"
            "  Refusing rather than emitting.\n"
            "\n"
            "  To accept a new upstream, deliberately:\n"
            "    1. cd %s && git log --oneline -5 -- %s\n"
            "    2. read the diff against the pinned revision above\n"
            "    3. update the pinned hash in %s, in the same commit that\n"
            "       regenerates the output, so git records the bump"
            % (generator, path, expect_sha256, upstream, got,
               os.path.dirname(os.path.dirname(path)) or "<upstream repo>",
               os.path.basename(path), generator))
    return got
