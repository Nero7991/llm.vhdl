# Shared plumbing for the FK33 SPI flash scripts (flash_backup, flash_program).
#
# Everything that talks to the flash -- READBACK INCLUDED -- has to get a
# Xilinx-supplied programmer bitstream into the FPGA first, and that is the one
# step the ES1 revision check can refuse.  So the load logic lives here once
# rather than being copied and drifting between the backup path and the program
# path.
#
# THE ES1 REVISION CHECK
# ----------------------
# This die is an ES1: JTAG IDCODE 0x04B69093, revision nibble 0, and
# hw_server's device table gives xcvu33p `bitstream_revisions = "es1;*"`, so
# nibble 0 means es1 and nibble 1 means production.  Vivado's
# program_hw_devices refuses a production-revision bitstream on it:
#
#   Bitstream was generated for part %s, target device (with IDCODE revision
#   %d) is compatible with %s revision bitstreams
#
# The check is enforced by the CLIENT, not by hw_server and not by silicon:
# hw_server reports an IS_REVISION_COMPATIBLE property and the client decides.
# xsdb.tcl:7602 does exactly that and offers -no-revision-check; Vivado's
# librdi_xicom_hw.so carries the matching XHWBitstream::setSkipRevisionCheck.
#
# The programmer bitstream Vivado loads is
# data/xicom/cfgmem/bitfile.zip -> bitfile/spi_xcvu33p_pullnone.bit, whose
# header names the PRODUCTION part xcvu33p-fsvh2104-1-e.  There is no es1
# variant of it anywhere in that zip.  So the check is EXPECTED to bite, and
# load_programmer tries the waiver automatically and reports which path worked.

proc envdef {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

# Open the hardware manager and return the hw_device.  Read only: nothing here
# configures anything, so it is safe to run against a card that is currently
# enumerated and serving PCIe.
proc fk33_open_device {} {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    if {[catch {open_hw_target [lindex [get_hw_targets] 0]} err]} {
        puts "FLASH_NO_TARGET: $err"
        puts "  No JTAG target.  The card is unpowered, or a stale hw_server"
        puts "  still holds the FTDI."
        exit 1
    }
    set devs [get_hw_devices]
    if {![llength $devs]} {
        puts "FLASH_NO_DEVICE: the JTAG chain is empty."
        exit 1
    }
    set dev [lindex $devs 0]
    current_hw_device $dev
    # TRAP from the handoff: `get_property REGISTER.IDCODE` does not exist on
    # this hw_device and aborts the script.  Do not add it back.  And use
    # -update_hw_probes false so refresh does not hunt for debug cores.
    refresh_hw_device -quiet -update_hw_probes false $dev
    return $dev
}

# Read VCCINT through the JTAG DRP.  Works with the PCIe link down and with no
# design clock, which the JTAG-AXI path does not: in the endpoint bitstream the
# whole AXI fabric is dead until the link is up, and the failed transactions
# that produces read like a card fault and are not one.
proc fk33_vccint {} {
    if {[catch {get_hw_sysmons} sms] || ![llength $sms]} { return unknown }
    set sm [lindex $sms 0]
    catch {refresh_hw_sysmon $sm}
    if {[catch {get_property VCCINT $sm} v]} { return unknown }
    return $v
}

# Refuse to do anything that depends on the die behaving correctly while VCCINT
# is below the -2L floor.  For the flash ERASE this is about not corrupting the
# part; for the READBACK it matters just as much for a different reason -- a
# quietly wrong backup that we then trust is worse than no backup at all.
proc fk33_vccint_gate {what} {
    set v [fk33_vccint]
    puts "  VCCINT     $v"
    if {$v eq "unknown"} { return $v }
    if {$v >= 0.70} { return $v }
    puts "  WARNING: VCCINT $v V is below the 0.698 V floor for the -2L grade."
    puts "           Raising it needs the probe bitstream (./pcieep.sh), which"
    puts "           reconfigures the FPGA -- but so does this script, so there"
    puts "           is nothing to preserve by skipping it.  Run ./pcieep.sh"
    puts "           first, then come back."
    puts "           Set FK33_FORCE_LOW_VCCINT=1 to proceed anyway."
    if {[envdef FK33_FORCE_LOW_VCCINT 0] == 0} {
        puts "FLASH_FAIL: refusing to $what at $v V"
        exit 1
    }
    return $v
}

# Load the flash programmer bitstream, trying the revision-check waiver only if
# the default refuses, so the run ANSWERS whether the check bites instead of
# hiding it.  A failed attempt is harmless: program_hw_devices fails at the
# FPGA load, long before anything reaches the flash.
#
# Returns 1 on success, 0 on failure.
proc fk33_load_programmer {dev} {
    set pbit [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    puts "  programmer $pbit"

    if {[envdef FK33_ASSUME_LOADED 0] != 0} {
        puts "  FK33_ASSUME_LOADED=1: skipping the Vivado device load, assuming"
        puts "  ./flash.sh --preload already put that file in via"
        puts "  `xsdb ... fpga -no-revision-check`."
        return 1
    }

    set forced [envdef FK33_SKIP_REVCHECK ""]
    if {$forced eq ""} { set order [list 0 1] } else { set order [list $forced] }

    set firstfail ""
    set err ""
    foreach skip $order {
        # Guarded: the param exists in 2023.2 (verified, default 0) but a
        # different release may rename it, and an unknown param is an error.
        if {[catch {set_param xicom.skip_bitstream_compatibility_check $skip} e]} {
            puts "  NOTE: xicom.skip_bitstream_compatibility_check unavailable: $e"
        }
        puts "  attempt with xicom.skip_bitstream_compatibility_check = $skip"
        create_hw_bitstream -quiet -hw_device $dev $pbit
        if {![catch {program_hw_devices $dev} err]} {
            if {$skip == 0} {
                puts "FLASH_REVCHECK_CLEAR: the device load passed the ES1"
                puts "  revision check with Vivado's default settings.  So the"
                puts "  check that blocks program_hw_devices on OUR bitstream"
                puts "  does not block the Xilinx-supplied programmer."
            } elseif {$firstfail ne ""} {
                puts "FLASH_REVCHECK_BIT: the ES1 revision check DID block the"
                puts "  load; xicom.skip_bitstream_compatibility_check 1 waived it."
                puts "  Blocked with: $firstfail"
            } else {
                puts "FLASH_REVCHECK_UNKNOWN: loaded with the waiver already on,"
                puts "  so this run does NOT establish whether the check would"
                puts "  have bitten.  Unset FK33_SKIP_REVCHECK to find out."
            }
            return 1
        }
        if {$firstfail eq ""} { set firstfail $err }
        puts "  load failed: $err"
    }

    puts "FLASH_REVCHECK_FATAL: could not load the flash programmer bitstream."
    puts "  first error: $firstfail"
    puts "  last  error: $err"
    puts "  Fallback: ./flash.sh --preload loads it with xsdb instead, which"
    puts "  has -no-revision-check and is the path tcl/program.tcl already"
    puts "  uses successfully on this die."
    return 0
}

# Create the hw_cfgmem object for the FK33's flash.  cfgmem id 193 in Vivado's
# xicom_cfgmem_part_table.csv is the SINGLE-device entry (NUM_CFG_FILES=1).
# Do NOT use mt25qu256-spi-x1_x2_x4_x8, which is the dual-parallel entry and
# expects two flash devices the FK33 does not have.
#
# get_cfgmem_parts returns the same name TEN times, once per compatible
# architecture; get_property on that list fails with "expects exactly one
# object got '10'".  Hence the lindex.
proc fk33_make_cfgmem {dev part} {
    if {[llength [get_property PROGRAM.HW_CFGMEM $dev]]} {
        delete_hw_cfgmem -quiet [get_property PROGRAM.HW_CFGMEM $dev]
    }
    create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $part] 0]
    return [get_property PROGRAM.HW_CFGMEM $dev]
}
