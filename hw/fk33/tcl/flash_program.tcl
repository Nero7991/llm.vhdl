# Write the endpoint image into the FK33's SPI flash, over JTAG.
#
# WHY THIS EXISTS
# ---------------
# A JTAG-configured FK33 can never enumerate on this host.  PCIe wants a
# trained link inside roughly 100 ms of PERST# deasserting; JTAG configuration
# takes far longer, so the BIOS gives up and hides the root port.  See
# docs/2026-08-28_fk33-first-fit-handoff.md section 0.  The only way out is for
# the FPGA to configure ITSELF at power-on out of the SPI flash.
#
# WHAT THIS DESTROYS, AND WHY IT IS NOT RECOVERABLE
# -------------------------------------------------
# Measured 2026-08-28: the card enumerates on this host RIGHT NOW, running the
# FACTORY image out of this same flash, as
# `1e24:1533 Squirrels Research Labs ForestKitten 33` behind root port 00:1d.0.
# PROGRAM.ERASE 1 destroys that image permanently.  It is SQRL's, we cannot
# rebuild it, and there is no copy of it in this repository.
#
# So this script REFUSES to run without a validated backup, unless
# FK33_ALLOW_NO_BACKUP=1 says the loss was chosen deliberately.  flash.sh
# enforces the same thing earlier and more loudly; the check is duplicated here
# so that running the Tcl directly cannot bypass it.
#
# Recovery after a bad write of OUR image is a different and much easier
# matter: JTAG configuration overrides the flash and does not depend on it, so
# a corrupt image costs a power cycle, not the card.  It is the FACTORY image
# that is irreplaceable, not ours.
#
# THE ES1 REVISION CHECK is handled in flash_common.tcl; see the header there.
#
# Env in:
#   FK33_MCS               .mcs to program (default hw/fk33/bit/fk33_pcieep.mcs)
#   FK33_BACKUP            factory backup that must exist (default
#                          hw/fk33/bit/fk33_factory_backup.mcs)
#   FK33_ALLOW_NO_BACKUP   1 to program with no backup.  Destroys the factory
#                          image with no way back except SQRL.
#   FK33_SKIP_REVCHECK     force the revision-check waiver on (1) or off (0)
#   FK33_ASSUME_LOADED     1 if ./flash.sh --preload already loaded the
#                          programmer bitstream via xsdb
#   FK33_CFGMEM_PART       override the cfgmem part id
#   FK33_PULL              programmer pin termination
#   FK33_VERIFY            1 (default) to read the flash back after writing
# Markers out: FLASH_BEGIN / FLASH_OK / FLASH_FAIL, plus FLASH_REVCHECK_*.

source [file join [file dirname [info script]] flash_common.tcl]

set here [file normalize [file dirname [info script]]/..]
set mcs  [envdef FK33_MCS    "$here/bit/fk33_pcieep.mcs"]
set bak  [envdef FK33_BACKUP "$here/bit/fk33_factory_backup.mcs"]
set part [envdef FK33_CFGMEM_PART {mt25qu256-spi-x1_x2_x4}]
set pull [envdef FK33_PULL {pull-none}]
set doverify [envdef FK33_VERIFY 1]

puts "FLASH_BEGIN"
puts "  mcs        $mcs"
puts "  cfgmem     $part"
puts "  pin pull   $pull"

if {![file exists $mcs]} {
    puts "FLASH_FAIL: .mcs missing: $mcs"
    puts "            run  ./flash.sh --mcs  first."
    exit 1
}

# ---------------------------------------------------------------- backup gate
if {[envdef FK33_ALLOW_NO_BACKUP 0] != 0} {
    puts "  backup     OVERRIDDEN (FK33_ALLOW_NO_BACKUP=1)"
    puts "  The SQRL factory image will be destroyed and cannot be rebuilt"
    puts "  from anything in this repository.  Proceeding because you said so."
} elseif {![file exists $bak] || [file size $bak] == 0} {
    puts "FLASH_FAIL: no factory backup at $bak"
    puts "  The card is currently running SQRL's factory image out of this"
    puts "  flash (1e24:1533, seen enumerated on 2026-08-28).  Erasing without"
    puts "  a copy of it is irreversible."
    puts "  Run  ./flash.sh --backup  first, or set FK33_ALLOW_NO_BACKUP=1."
    exit 1
} else {
    puts "  backup     $bak ([file size $bak] bytes)"
}

set dev [fk33_open_device]
puts "  device     [get_property PART $dev] ([get_property NAME $dev])"
fk33_vccint_gate "erase the flash"

# ---------------------------------------------------------------- cfgmem
set cm [fk33_make_cfgmem $dev $part]
set_property PROGRAM.FILES              [list $mcs] $cm
set_property PROGRAM.PRM_FILE           [file rootname $mcs].prm $cm
set_property PROGRAM.ADDRESS_RANGE      {use_file}  $cm
set_property PROGRAM.UNUSED_PIN_TERMINATION $pull   $cm
set_property PROGRAM.BLANK_CHECK        0           $cm
set_property PROGRAM.ERASE              1           $cm
set_property PROGRAM.CFG_PROGRAM        1           $cm
set_property PROGRAM.VERIFY             $doverify   $cm
set_property PROGRAM.CHECKSUM           0           $cm

if {![fk33_load_programmer $dev]} {
    puts "FLASH_FAIL"
    exit 1
}

# ---------------------------------------------------------------- program
puts "  erasing and programming (this takes minutes, not seconds)"
if {[catch {program_hw_cfgmem -hw_cfgmem $cm} err]} {
    puts "FLASH_FAIL: program_hw_cfgmem: $err"
    exit 1
}
puts "FLASH_OK"
puts "  The image is in flash.  It does NOT take effect until the card is"
puts "  POWER CYCLED: a warm reboot leaves the FPGA holding whatever it was"
puts "  last configured with, and will not re-read the flash."
puts "  Next: full shutdown, mains off, power on, then ./flash.sh --status."
