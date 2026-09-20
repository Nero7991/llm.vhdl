#!/usr/bin/env python3
"""Intersect the FLAT image's KV slot grid with the RESIDENT image's pieces."""
import json, sys
sys.path.insert(0, '/home/orencollaco/GitHub/llama.vhdl/tools')
import hbm_map as HM
flat = json.load(open('/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json'))
res  = json.load(open('/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped-seg27/manifest.json'))
K   = flat['hbm']['kv_base']
bpt = flat['hbm']['kv_bytes_per_token']
MP  = 65536                      # the card's C_MAXPOS, read from FK33_SEAM_KV_MAXPOS
half   = MP * (bpt // 2)
V      = K + half
stride = MP * 272                # kv_record_bytes
pieces = [(p['hbm_offset'], p['hbm_offset'] + p['nbytes'], e['file'])
          for e in res['files'] for p in HM.file_pieces(e)]
print("K 0x%X  V 0x%X  half 0x%X  slot stride 0x%X" % (K, V, half, stride))
for NT in (1, 8, 16, 24, 32, 34):
    hit = set()
    for s in [K + i*stride for i in range(32)] + [V + i*stride for i in range(32)]:
        for a, b, f in pieces:
            if a < s + NT*272 and s < b:
                hit.add(f)
    print("NTOK %2d -> %d distinct weight objects predicted destroyed" % (NT, len(hit)))
