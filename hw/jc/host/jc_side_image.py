#!/usr/bin/env python3
"""Build the JC "side image": the HBM bytes the FK33 host wrote by DMA and the JC host cannot.

    jc_side_image.py <manifest.json> <rundir>

<rundir> must already hold token.arena from tools/gen_layer_program.py --token ... for this
manifest. Writes into <rundir>:
    gdn_zero.bin     hbm.gdn_state_bytes of zeros (the GDN state reset fk33_chat2.sh does)
    imglock.bin      the 512-byte image record fk33_load_weights.py writes after a load
                     (hw/fk33/host/fk33_imgfp.py pack_record, at record_addr)
    side.json        a coe_load.py manifest: token.arena at hbm.desc_arena_base,
                     gdn_zero.bin at hbm.gdn_state_base, imglock.bin at the record address
    side_gdn.json    the same with gdn_zero.bin only (re-zero between sequences)
and plans both with tools/jc/coe_load.py's plan_frames (alignment, range, stack line,
digests) for dies A and B, printing `SIDE_OK <path> <frames> ...` per manifest.

WHY: the JC transport refuses every HBM write (server/fk33_transport_jc.c, mem_write is
-EPERM: "the loader is the only HBM writer"), so the token program's descriptor arena, the
GDN state zero and the image record go in through `coe_load.py load side.json`, with the
broker stopped (one BMC owner). Host-only: touches no board.
"""
import hashlib, json, os, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path[:0] = [os.path.join(REPO, "hw/fk33/host"), os.path.join(REPO, "tools")]
import fk33_load_weights as FLW, fk33_imgfp as IMGFP
from jc import coe_load as L
if len(sys.argv) != 3:
    sys.exit("usage: jc_side_image.py <manifest.json> <rundir>")
man, run = sys.argv[1], sys.argv[2]
mani = json.load(open(man)); h = mani["hbm"]
zero = os.path.join(run, "gdn_zero.bin")
if not os.path.exists(zero) or os.path.getsize(zero) != h["gdn_state_bytes"]:
    with open(zero, "wb") as f: f.truncate(h["gdn_state_bytes"])
ents = FLW.select(mani, None)
with open(os.path.join(run, "imglock.bin"), "wb") as f:
    f.write(IMGFP.pack_record(mani, man, len(ents), len(ents), sum(int(e["nbytes"]) for e in ents)))
def ent(name, off):
    p = os.path.join(run, name); d = hashlib.blake2b(digest_size=16)
    with open(p, "rb") as fh:
        for c in iter(lambda: fh.read(1 << 24), b""): d.update(c)
    return dict(file=name, kind="f32blob", tensor="<JC host-side %s>" % name,
                hbm_offset=int(off), nbytes=os.path.getsize(p), blake2b_128=d.hexdigest())
arena = ent("token.arena", h["desc_arena_base"])
assert arena["nbytes"] <= h["desc_arena_bytes"] - IMGFP.RECORD_BYTES, "arena would overwrite the image record"
gdn = ent("gdn_zero.bin", h["gdn_state_base"])
rec = ent("imglock.bin", IMGFP.record_addr(mani))
for name, files in (("side.json", [arena, gdn, rec]), ("side_gdn.json", [gdn])):
    p = os.path.join(run, name)
    json.dump({"format": "llama.vhdl JC side image (token arena, GDN state zero, image record)",
               "source_manifest": os.path.abspath(man), "files": files}, open(p, "w"), indent=1)
    for d in "AB":
        frames, sha = L.plan_frames(p, die=d)
    print("SIDE_OK %s %d frames (die %s plan %s) %s" % (p, len(frames), d, sha[:12],
          " ".join("%s@%#x+%d" % (e["file"], e["hbm_offset"], e["nbytes"]) for e in files)))
