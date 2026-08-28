# Read the FK33's SPI flash back to a file, BEFORE anything erases it.
#
# WHY THIS IS THE FIRST THING THAT HAPPENS
# ----------------------------------------
# Measured 2026-08-28: the card enumerates on this host RIGHT NOW, running the
# FACTORY image out of this same flash:
#
#   06:00.0 Serial controller [0700]: Squirrels Research Labs
#           ForestKitten 33 [1e24:1533] (rev a3)   behind root port 00:1d.0
#
# That is SQRL's device ID, not our 10ee:9034.  It is not published anywhere we
# can re-download it from, so `PROGRAM.ERASE 1` destroys it permanently unless
# it is copied off first.  This is that copy.
#
# READBACK IS ITSELF A JTAG CONFIGURATION.  READ THIS BEFORE RUNNING IT.
# ----------------------------------------------------------------------
# There is no way to read the flash without driving it, and the only thing on
# the board that can drive it is the FPGA.  So readback_hw_cfgmem loads the
# same Xilinx programmer bitstream that programming does, which OVERWRITES the
# factory design running in the FPGA's SRAM.  The card will drop off the PCIe
# bus the moment this runs and will not come back until a power cycle.
#
# That is recoverable, and it is recoverable precisely because the flash is
# still intact: a power cycle reloads the factory image and the card
# re-enumerates.  It stops being recoverable after the erase.  So "back up
# before any JTAG configuration" is not achievable; "back up before anything
# IRREVERSIBLE" is, and that is what this script is for.
#
# WHAT A GOOD BACKUP LOOKS LIKE, AND WHY WE CHECK
# -----------------------------------------------
# A readback that returns all 0xFF or all 0x00 is a FAILED READ, not an empty
# flash.  That is the same class of trap as the handoff's "a failed JTAG-AXI
# transaction reports as -1, not as an error": a plausible-looking value that
# is really the absence of an answer.  A 32 MB file of 0xFF would pass every
# "does the file exist and is it non-empty" test and would be worthless.
# check_flash_backup.py validates the contents properly, by looking for the
# Xilinx sync word, and flash.sh refuses to program until it passes.
#
# Env in:
#   FK33_BACKUP        output .mcs (default hw/fk33/bit/fk33_factory_backup.mcs)
#   FK33_CFGMEM_PART   override the cfgmem part id
#   FK33_PULL          programmer pin termination: pull-none|pull-up|pull-down
# Markers out: BACKUP_BEGIN / BACKUP_OK / BACKUP_FAIL, plus the FLASH_REVCHECK_*
#              markers from flash_common.tcl.

source [file join [file dirname [info script]] flash_common.tcl]

set here   [file normalize [file dirname [info script]]/..]
set out    [envdef FK33_BACKUP "$here/bit/fk33_factory_backup.mcs"]
set part   [envdef FK33_CFGMEM_PART {mt25qu256-spi-x1_x2_x4}]
set pull   [envdef FK33_PULL {pull-none}]

puts "BACKUP_BEGIN"
puts "  out        $out"
puts "  cfgmem     $part"
puts "  pin pull   $pull"
puts ""
puts "  This reconfigures the FPGA and will drop the card off the PCIe bus."
puts "  A power cycle brings the factory image back, because the flash is"
puts "  still intact at this point.  That is the whole reason to do this now."
puts ""

file mkdir [file dirname $out]

set dev [fk33_open_device]
puts "  device     [get_property PART $dev] ([get_property NAME $dev])"
fk33_vccint_gate "read the flash back"

set cm [fk33_make_cfgmem $dev $part]
set_property PROGRAM.UNUSED_PIN_TERMINATION $pull $cm

if {![fk33_load_programmer $dev]} {
    puts "BACKUP_FAIL: the flash programmer bitstream would not load."
    puts ""
    puts "  ################################################################"
    puts "  # THE FACTORY IMAGE CANNOT BE BACKED UP ON THIS DIE.           #"
    puts "  # If you erase the flash it is gone, and the only source of a  #"
    puts "  # replacement is SQRL.  Decide that deliberately before        #"
    puts "  # running ./flash.sh --program --force-no-backup.              #"
    puts "  ################################################################"
    exit 1
}

# -all reads every address on the device (32 MB) rather than only the range a
# PROGRAM.FILES image would occupy.  We deliberately do NOT set PROGRAM.FILES
# here: we do not know how much of the flash the factory image uses, and a
# readback sized to OUR payload would silently truncate whatever sits above it
# (a golden image, a MultiBoot second stage, serial numbers).
puts "  reading back the whole 32 MB device.  This takes a long time."
if {[catch {readback_hw_cfgmem -force -all -file $out -format mcs $cm} err]} {
    puts "BACKUP_FAIL: readback_hw_cfgmem: $err"
    exit 1
}

if {![file exists $out] || [file size $out] == 0} {
    puts "BACKUP_FAIL: readback produced no file, or an empty one."
    exit 1
}
puts "  wrote [file size $out] bytes"
puts "BACKUP_OK"
puts "  NOT YET TRUSTED.  flash.sh now runs check_flash_backup.py over it;"
puts "  an all-0xFF or all-0x00 readback is a failed read that looks like a"
puts "  successful one."
