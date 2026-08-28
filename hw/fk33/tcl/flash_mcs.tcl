# Turn a .bit into the .mcs image that goes into the FK33's SPI flash.
#
# NO HARDWARE IS TOUCHED BY THIS SCRIPT.  It is pure file conversion, so it can
# be run with the card unpowered, unplugged, or absent.  flash.sh runs it under
# a plain `vivado -mode batch`, NOT under ./jtag.sh, because jtag.sh resets the
# FTDI cable first and that fails outright when the card is not powered.
#
# WHY A .MCS AT ALL
# -----------------
# The FPGA's master-SPI configuration engine reads a raw byte stream out of the
# flash.  The .bit file is that byte stream plus a ~130 byte ASCII header that
# names the part and the build date.  write_cfgmem strips the header, pads to
# the flash geometry, and emits Intel hex.
#
# The .mcs FILE is about 33 MB for a 12 MB bitstream.  That is ASCII hex
# overhead and it is NOT what the FPGA clocks in.  The number that matters for
# the configuration-time budget is the END ADDRESS that write_cfgmem prints:
# that is the last flash byte the FPGA has to read.  Measured 2026-08-28 for
# fk33_pcieep.bit (12,227,950 bytes on disk):
#
#   Addr1 0x00000000   Addr2 0x00BA94EB   ->  12,227,820 bytes of payload
#
# So payload = .bit minus the header, and the .mcs file size is irrelevant.
# See docs/debugging/2026-08-28_fk33-spi-flash-boot.md for what that costs in
# milliseconds and why it is the whole risk of this exercise.
#
# Env in:
#   FK33_BIT   bitstream to load at address 0 (default hw/fk33/bit/fk33_pcieep.bit)
#   FK33_MCS   output .mcs                    (default alongside the .bit)
# Markers out:  MCS_OK / MCS_FAIL, MCS_PAYLOAD_BYTES

proc envdef {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

set here [file normalize [file dirname [info script]]/..]
set bit  [envdef FK33_BIT "$here/bit/fk33_pcieep.bit"]
set mcs  [envdef FK33_MCS [file rootname $bit].mcs]

puts "MCS_BEGIN"
puts "  bit  $bit"
puts "  mcs  $mcs"

if {![file exists $bit]} {
    puts "MCS_FAIL: bitstream missing: $bit"
    exit 1
}

# 32 MB part.  mt25qu256-spi-x1_x2_x4 is cfgmem id 193 in Vivado's
# xicom_cfgmem_part_table.csv; it is the SINGLE-device entry (NUM_CFG_FILES=1).
# Do not reach for mt25qu256-spi-x1_x2_x4_x8, which is the dual-parallel entry
# and expects two flash devices the FK33 does not have.
#
# -interface SPIx4 must match CONFIG_MODE / BITSTREAM.CONFIG.SPI_BUSWIDTH in
# fk33_pcieep.xdc, or the FPGA will read the flash in a width the image was not
# laid out for.
if {[catch {
    write_cfgmem -force -format mcs -size 32 -interface SPIx4 \
        -loadbit "up 0x00000000 $bit" -file $mcs
} err]} {
    puts "MCS_FAIL: $err"
    exit 1
}

# Recover the payload length from the .prm sidecar that write_cfgmem writes
# next to the .mcs.  It carries the same Addr1/Addr2 pair that the console
# banner prints, and it is the only machine-readable form of it.
set prm [file rootname $mcs].prm
set payload unknown
if {[file exists $prm]} {
    set fh [open $prm r]
    set txt [read $fh]
    close $fh
    # The first pair of bare hex words in the file is the Addr1/Addr2 column of
    # the load table.  The Start/End Address lines above it cannot match the
    # pair, because "End Address" sits between them and \s does not cover it.
    if {[regexp {0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)} $txt -> a1 a2]} {
        set payload [expr {[scan $a2 %x] - [scan $a1 %x] + 1}]
    }
}
puts "MCS_PAYLOAD_BYTES $payload"
if {$payload ne "unknown"} {
    # Configuration time, at the nominal CONFIGRATE in fk33_pcieep.xdc.
    # SPIx4 clocks 4 bits per CCLK, so bits/(4*f).  The +-15% band is FMCCKTOL,
    # the internal configuration oscillator's tolerance (DS923).
    set bits [expr {$payload * 8.0}]
    foreach f {127.5 108.4 146.6} {
        puts [format "  config time at CCLK %6.1f MHz (SPIx4): %6.1f ms" \
              $f [expr {$bits / ($f * 4.0e6) * 1000.0}]]
    }
    puts "  127.5 = nominal, 108.4 = nominal -15%, 146.6 = nominal +15%."
    puts "  NOTE 146.6 MHz is NOT a legal operating point: DS923 gives FMCCK"
    puts "       max 125 MHz for master SPI x1/x2/x4 on this device, and the"
    puts "       MT25QU256 is a 133 MHz part.  Treat 108.4 as the honest case."
}
puts "MCS_OK bytes=[file size $mcs]"
