# FK33 floorplan -- keep the engine out of Tandem PCIe's reserved column.
#
# IMPLEMENTATION ONLY.  The build sets `used_in_synthesis false` on this file
# and asserts that it took, because `bd_i/eng/inst/eng/dut/core` is a path in
# the LINKED design and does not exist during synthesis; get_cells would return
# nothing and add_cells_to_pblock errors on an empty object.
#
# ---------------------------------------------------------------------------
# THIS FILE IS NOT WHAT MADE THE DESIGN ROUTE.  READ THIS FIRST.
# ---------------------------------------------------------------------------
#
# The first build containing subsystem A placed and would not route:
#     ERROR: [Route 35-3] Design is not routable as its global congestion
#     level is 7.
#
# The cause was an INHERITED constraint, not a placer preference.  SQRL's shell
# floorplan, carried into fk33_i2cprobe.xdc and from there into
# fk33_pcieep.xdc, assigned the WHOLE block design `[get_cells bd_i]` to a
# pblock `pblock_bd_i` covering SLICE_X0Y0:X218Y50 -- 51 SLICE rows, less than
# one clock-region row -- plus the rightmost 14 SLICE columns.  It is IS_SOFT,
# so instead of failing it crammed what it could into an area holding 67% of
# the assigned LUTs and 33% of the assigned DSPs and spilled the rest.  That
# spill is the whole congestion story.
#
# `gen_pcieep.py` now comments those 13 lines out of the emitted XDC, and the
# post-implementation block asserts pblock_bd_i is absent.  MEASURED
# (docs/debugging/2026-08-29_shell-pblock.md): deleting it and changing NOTHING
# else takes the placed core clock from WNS -0.759 to +0.416 with zero failing
# endpoints, and congestion from 23 windows with a level 7 to 5 windows with a
# worst of 6.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE IS FOR
# ---------------------------------------------------------------------------
#
# TRACK TANDEM (`abbd2ed`, docs/2026-08-29_pcie-reconfiguration-options.md)
# measured that Tandem PCIe reserves SLICE_X216Y0:SLICE_X232Y239 -- clock-region
# column X7 in all four rows, 7.31% of the slices and 6.25% of the DSPs -- as a
# hard exclusion zone for non-stage-one logic, enforced by `DRC HDTC-6`,
# severity Error.  Tandem is on this project's path because it is the
# documented fix for the PCIe cold-boot budget.
#
# `matvec_core` is 68% of the design's LUTs and 99.9% of its DSPs, so if the
# engine is going to have to leave that column one day, the cheapest time to
# find out what it costs is now.  MEASURED: it costs nothing.  Inside this
# pblock the core sits at 118,550 of 388,800 LUT sites (30.49%) and 1,584 of
# 2,700 DSP sites (58.67%), and the resulting placement is as good as the
# unconstrained one on every axis measured -- 5 congested windows, worst level
# 6, placed WNS +0.379 with zero failing endpoints.
#
# THIS DOES NOT MAKE THE DESIGN TANDEM-READY.  Only matvec_core is constrained.
# The other ~55,000 LUTs are free to land in column X7, and xdma's PCIe4C hard
# block and its GTY quad are physically there by necessity.  All this buys is
# that the engine is already out of the way.
#
# ---------------------------------------------------------------------------
# THINGS THAT LOOK LIKE THEY WOULD WORK AND DO NOT
# ---------------------------------------------------------------------------
#
#   * A pblock covering CLOCKREGION_X0Y0:X7Y3 is the whole device and therefore
#     not a constraint at all.  A pblock only does work here if it REMOVES area.
#   * `place_design -directive AltSpreadLogic_high`, Vivado's own
#     congestion-spreading directive, does NOT fix this on its own.  MEASURED:
#     with pblock_bd_i still present it moves the core's clock-region
#     distribution by about six points and leaves the design unroutable.
#   * A pblock is a strong preference with a small measured leak, not absolute
#     containment.  MEASURED on a routed checkpoint: 1,077 of 220,180
#     matvec_core leaves, 0.49%, sat outside their own pblock with no DRC
#     error, most of them MUXF7/MUXF8, which Vivado places as indivisible
#     shapes.  Do not rely on a pblock for anything that has to be exact.

create_pblock pb_core
add_cells_to_pblock [get_pblocks pb_core] [get_cells bd_i/eng/inst/eng/dut/core]
resize_pblock [get_pblocks pb_core] -add {CLOCKREGION_X0Y0:CLOCKREGION_X6Y3}
