#!/usr/bin/env python3
"""tools/genstamp.py -- one deterministic header block naming the OUT-OF-BAND
inputs that produced a generated file.

WHY THIS EXISTS.  CLAUDE.md already says to check line 2 of any generated file
before editing it, and that rule is performable by reading the file in front of
you.  MEASURED 2026-09-20 (TRACK BUILDREPORT): it is not enough.
`hw/fk33/build_fk33_pcieep.tcl` carries a correct line-2 banner, and its
COMMITTED form was produced with `FK33_CARD=1` plus `FK33_CB_STYLE=distributed`
plus a 75 MHz CLKOUT3 -- none of which the file records.  Regenerating it with
the default environment, which is the remedy the banner invites, silently
changed its CONFIGURATION: 497 deletions, the whole lever-C block, in a diff
that looks like ordinary drift.  The prescribed fix DESTROYS the only evidence
of what the file was.

So a generated file needs to state not only THAT it was generated but WITH
WHAT.  This module emits that statement, in one uniform shape, from the
generator itself.

PRIOR ART IN THIS TREE, and it is the argument for the whole idea.
`tools/gen_hbm_tg_ip.py` has always written `Regenerate with:  python3
tools/gen_hbm_tg_ip.py 30` into its own output.  MEASURED 2026-09-20: running
that exact line reproduces the committed `rtl/hbm_tg_ip.vhd` BYTE-FOR-BYTE,
while running the generator with no argument (its default NPORT=16) deletes
1,025 of its 1,028 lines.  The argument was recoverable for exactly one reason:
the file said what it was.  `hw/fk33/build_fk33_hbmbw.tcl`, from the same
family, says nothing, and recovering its `30 300` took three attempts and
produced one false positive on the way (see the trap note below).

DETERMINISM IS A HARD REQUIREMENT, NOT A PREFERENCE.  Five gate rows
(`sim:cardtop`, `sim:gdnstale`, `sim:c4stale`, `sim:fk33card`, `sim:ipsync`)
regenerate a file and compare it against the committed bytes.  A stamp carrying
a timestamp, a username, a hostname or a working directory makes every one of
those rows fail on every machine, so the stamp carries NONE of them: only the
names of the inputs and their values, in sorted order.  `rtl/ooc_cattnadapt_top.vhd`
is the recorded counter-example -- its "Regenerate with" line embeds a
`/tmp/claude-.../scratchpad/...` path from the session that made it, which is
both non-reproducible and now deleted.

WHAT COUNTS AS AN INPUT.  Anything that changes the BODY and is not in the
generator's source or in a file the generator reads: environment variables,
argv values, and defaults that were taken rather than given.  A value that was
NOT supplied is stamped `(unset)` rather than omitted, because an omitted line
and an absent variable are indistinguishable to the reader, and knowing that a
knob EXISTS and was left alone is most of the value.
"""

import re
import shlex


def stamp(cmd, inputs, comment="--"):
    """Return the GENSTAMP block as a string ending in a newline.

    `cmd`     list of argv tokens that reproduces this exact file, e.g.
              ["python3", "tools/gen_hbm_tg_ip.py", "30"].  Must be built from
              the same values as `inputs`, never from `sys.argv`, so that a
              `--check` run and a write run produce identical text.
    `inputs`  iterable of (kind, name, value) where kind is "env" or "argv",
              name is the variable or parameter name, and value is a string or
              None for "not supplied".  Order is IGNORED: the block sorts by
              (kind, name) so two runs with the same values agree byte for byte
              however the caller assembled the list.
    `comment` the target language's line-comment marker ("--" for VHDL, "#"
              for Tcl / shell / Python).
    """
    rows = sorted(((str(k), str(n), v) for (k, n, v) in inputs),
                  key=lambda r: (r[0], r[1]))
    width = max([len(n) for (_, n, _) in rows] + [0])
    c = comment
    out = [
        "%s GENSTAMP -- the out-of-band inputs that produced THIS file, and" % c,
        "%s the only record of them.  This generator's output DEPENDS on the" % c,
        "%s values below: regenerating with different ones changes the" % c,
        "%s CONFIGURATION, not the formatting, and the diff looks like" % c,
        "%s ordinary drift.  Reproduce this exact file with" % c,
        "%s     %s" % (c, " ".join(shlex.quote(t) for t in cmd)),
    ]
    if not rows:
        # A POSITIVE statement of no dependence, not an omission.  An absent
        # stamp and an empty one are different claims: the first says nobody
        # looked, the second says someone did and there is nothing to record.
        out.append("%s inputs: NONE.  This file's content depends only on its"
                   % c)
        out.append("%s     generator and the files that generator reads, so"
                   % c)
        out.append("%s     the command above reproduces it from any shell."
                   % c)
        return "\n".join(out) + "\n"
    out.append("%s inputs ((unset) means the generator's own default was "
               "taken):" % c)
    for kind, name, value in rows:
        out.append("%s     %-4s %-*s = %s"
                   % (c, kind, width, name, "(unset)" if value is None
                      else str(value)))
    return "\n".join(out) + "\n"


def insert_after(text, marker, block):
    """Insert `block` immediately after the first line containing `marker`.

    Returns the new text.  Raises if the marker is absent, rather than
    appending somewhere plausible: a stamp that silently lands in the wrong
    place is worse than a generator that refuses to run, because nothing
    downstream would notice.
    """
    lines = text.splitlines(True)
    for i, line in enumerate(lines):
        if marker in line:
            return "".join(lines[:i + 1]) + block + "".join(lines[i + 1:])
    raise ValueError("genstamp: marker %r not found in generated text" % marker)


def append_end(text, block, comment):
    """Append `block` at the END of `text`, after a blank separator line.

    WHY THIS EXISTS, AND IT IS A MEASURED COST RATHER THAN A PREFERENCE.
    MEASURED 2026-09-20 (TRACK TCLOWNER): putting the stamp at the TOP of
    `hw/fk33/fk33_pcieep.xdc` inserted 19 lines there in commit `08cc17d` and
    moved ALL ELEVEN human line-number citations into that file by exactly 19.
    Every one of them was correct at `08cc17d^`.  Nothing else changed in the
    file in that commit, so the attribution is clean.

    The one-off breakage is not the durable part of the argument.  The stamp's
    HEIGHT is the number of inputs plus five, so it changes whenever an input
    is added: `gen_pcieep.py` stamps nine environment variables today, and a
    tenth would shift every citation into its output by one, again, silently.
    **A top stamp re-breaks the citations on every change to the input list; an
    end stamp never moves the body at all.**  That is why this is the right
    placement for any generated file people cite into, and it is why the fixed
    banner stays at the top while only the variable-height block moves.

    ONLY SAFE FOR A COMMENT-ONLY BLOCK, AND THAT IS CHECKED HERE RATHER THAN
    ASSUMED.  A constraints file is order-dependent -- a later `set_property`
    overrides an earlier one -- so moving real directives to the end would
    change the design, not just the layout.  Every line `stamp()` emits begins
    with the comment marker, which makes the block inert at any position; this
    function REFUSES a block for which that is not true rather than trusting
    the caller, because the failure it would cause is a silent constraint
    reordering that no bench can see.
    """
    for line in block.splitlines():
        if line.strip() and not line.lstrip().startswith(comment):
            raise ValueError(
                "genstamp.append_end: refusing to append a block containing a "
                "non-comment line (%r) with marker %r -- at the end of an "
                "order-dependent file that would change its meaning, not its "
                "formatting" % (line, comment))
    if not text.endswith("\n"):
        text += "\n"
    return text + "\n" + block


# MEASUREMENT TRAP HIT WHILE BUILDING THIS, recorded because it produced a
# WRONG RESULT THAT LOOKED RIGHT.  Recovering `build_fk33_hbmbw.tcl`'s
# arguments was done by regenerating under candidate values and diffing.  The
# candidate `31 300` was reported as reproducing the committed file exactly --
# and `hw/fk33/gen_hbmbw.py` had in fact REFUSED it ("NPORT must be 15 or 30")
# and exited WITHOUT WRITING.  The generator's stdout and stderr were sent to
# /dev/null, so an unwritten file compared equal to itself and read as a
# perfect match.  This is CLAUDE.md's "a completion signal that also fires on
# failure" in a new place: the diff was reporting a fact about the harness.
# Check the generator's exit status and let it print, and prefer a reproduction
# test that must CHANGE something (regenerate under a different value first,
# then back) over one that must change nothing.


# ---------------------------------------------------------------------------
# READING A STAMP BACK.  Added 2026-09-20 by TRACK GENGATE.
#
# WHY.  A `--check` row regenerates a committed file and diffs it, and that is
# only a staleness test if it regenerates with the SAME inputs.  Two of this
# tree's committed generated files take an argument whose committed value is
# NOT the generator's default -- rtl/hbm_tg_ip.vhd is NPORT=30 against a
# default of 16, hw/fk33/build_fk33_hbmbw.tcl is 30 300 against 15 300 -- so a
# check written the obvious way reports STALE forever, on a tree that is
# perfectly current.  A check that is always red is worse than no check: it
# gets muted, and then the row is decoration.
#
# The stamp already records those values, which is the whole point of it, so
# the check reads them back out of the file it is checking.  That makes the
# committed file self-describing in both directions: a human reads the
# reproduce line, and the gate reads the rows.
_ROW_RE = re.compile(r"^\s*(?:--|#|//)\s+(env|argv)\s+(\S+)\s*=\s*(.*?)\s*$")
_ROWS_HDR = "inputs ((unset) means"
_NO_INPUTS = "inputs: NONE."


def parse(text):
    """Return the stamped [(kind, name, value)] rows, value None for (unset).

    Raises ValueError when the text carries no GENSTAMP block at all, rather
    than returning [] -- an unstamped file and a file stamped "inputs: NONE"
    are DIFFERENT CLAIMS (nobody looked, versus someone looked and there is
    nothing to record), and a caller that cannot tell them apart would fall
    back to a generator default and call the result current.

    The scan is BOUNDED to the rows immediately following the header line and
    stops at the first line that is not a row.  An unbounded regex over a
    whole generated file can match its body: a Tcl or VHDL comment of the form
    `# env FOO = bar` is ordinary text, and CLAUDE.md records four separate
    incidents in this project of a search matching something it was not
    looking for.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if _NO_INPUTS in line:
            return []
        if _ROWS_HDR in line:
            rows = []
            for line in lines[i + 1:]:
                m = _ROW_RE.match(line)
                if not m:
                    break
                rows.append((m.group(1), m.group(2),
                             None if m.group(3) == "(unset)" else m.group(3)))
            if not rows:
                raise ValueError(
                    "genstamp: the block header is present but no input rows "
                    "follow it, so the file records the existence of inputs "
                    "and not their values")
            return rows
    raise ValueError("genstamp: no GENSTAMP block found; this file does not "
                     "record what produced it, so nothing can regenerate it "
                     "with the right inputs")


def read_inputs(path):
    """parse() the file at `path`.  Errors name the path."""
    try:
        return parse(open(path).read())
    except ValueError as e:
        raise ValueError("%s: %s" % (path, e))


def value(rows, kind, name, cast=str, default=None):
    """One stamped value, or `default` when the stamp does not carry it."""
    for k, n, v in rows:
        if k == kind and n == name:
            return default if v is None else cast(v)
    return default
