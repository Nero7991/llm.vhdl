"""tools/rate/config.py -- constants shared by the rating flow
(docs/superpowers/specs/2026-09-25-block-ratings-design.md)."""
import os
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VIVADO_ROOT = "/tools/Xilinx/2023.2/Vivado/2023.2"
VIVADO_VERSION = os.path.basename(VIVADO_ROOT)
TARGETS = os.path.join(REPO, "hw", "targets")
WORK_ROOT = "/mnt/storage/fk33_builds/ratings"     # never /tmp (CLAUDE.md HOUSE STYLE)
RTL_DIRS = ("rtl", os.path.join("hw", "fk33", "rtl"))
