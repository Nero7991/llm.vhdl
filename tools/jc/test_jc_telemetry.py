import os
import pytest
from tools.jc import jc_telemetry as T

HERE = os.path.dirname(os.path.abspath(__file__))
DIES = {"A": "<redacted>", "B": "<redacted>"}


def _fx(name):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return f.read()


def test_two_fpga_scan_maps_devices_by_dna_not_index():
    s = T.parse_scan(_fx("bridge_scan_2fpga.txt"), DIES)
    assert s["nfpga"] == 2 and s["slot_b_switch"] is False
    a, b = s["jtag"]["A"], s["jtag"]["B"]
    assert a["slr0_temp"] == 49.531 and a["slr1_vccint"] == 0.855
    assert a["slr0_vccbram"] == 0.861 and a["led"] == "--B --C-"
    assert b["slr1_temp"] == 58.981 and b["slr0_vccaux"] == 1.790


def test_bmc_telemetry_takes_the_first_block_per_fpga():
    s = T.parse_scan(_fx("bridge_scan_2fpga.txt"), DIES)
    a, b = s["bmc"]["A"], s["bmc"]["B"]
    assert a["vrm_a"] == 1.50 and a["hbm_a"] == 0.75   # first block, not the 0.88 repeat
    assert b["vrm_temp"] == 56 and b["vrm_v"] == 0.848 and b["hbm_v"] == 1.230
    assert b["t0"] == 58.48 and b["v1"] == 0.850


def test_one_fpga_scan_is_die_b_by_dna_and_flags_the_slot_switch():
    s = T.parse_scan(_fx("bridge_scan_1fpga.txt"), DIES)
    assert s["nfpga"] == 1 and s["slot_b_switch"] is True
    assert list(s["jtag"]) == ["B"]
    assert s["jtag"]["B"]["slr0_temp"] == 60.473
    assert T.alarm(s) == "ALARM nfpga=1 slot_b_switch=1 missing=A"


def test_healthy_scan_raises_no_alarm():
    assert T.alarm(T.parse_scan(_fx("bridge_scan_2fpga.txt"), DIES)) is None


def test_unknown_dna_is_kept_under_its_suffix_not_dropped():
    s = T.parse_scan(_fx("bridge_scan_2fpga.txt"), {"A": DIES["A"]})
    assert set(s["jtag"]) == {"A", "dna_bbbb"}


def test_csv_rows_have_a_fixed_header_and_one_row_per_source_and_die():
    s = T.parse_scan(_fx("bridge_scan_2fpga.txt"), DIES)
    rows = T.csv_rows("2026-10-07T19:00:00-04:00", s)
    assert [r[:3] for r in rows] == [
        ["2026-10-07T19:00:00-04:00", "jtag", "A"], ["2026-10-07T19:00:00-04:00", "jtag", "B"],
        ["2026-10-07T19:00:00-04:00", "bmc", "A"], ["2026-10-07T19:00:00-04:00", "bmc", "B"]]
    assert all(len(r) == len(T.CSV_HEADER) for r in rows)


def test_empty_output_is_a_failed_scan_not_a_healthy_one():
    s = T.parse_scan("Connecting...\n", DIES)
    assert s["nfpga"] == 0
    assert T.alarm(s).startswith("ALARM nfpga=0")
