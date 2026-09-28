link_design -part xcvu35p-fsvh2104-2-e
foreach p {AD38 AD39} { set pp [get_package_pins $p]; puts "PINQ $p [get_property PIN_FUNC $pp] bank=[get_property BANK $pp]" }
foreach b [lsort [get_iobanks -filter {BANK_TYPE =~ *GTY*}]] { puts "BANKQ $b" }
set bk [get_property BANK [get_package_pins AD38]]
foreach pp [lsort [get_package_pins -filter "BANK == $bk"]] { puts "QPIN $pp [get_property PIN_FUNC $pp]" }
puts PINQ_DONE
