#!/usr/bin/env python3
"""tools/jc/gen_tok_loop_vec.py -- sim/tok_loop_vec.txt from run_prompt's own host sequence.

    python3 tools/jc/gen_tok_loop_vec.py [--out sim/tok_loop_vec.txt] [--check]

Each case starts server/jc_sim_broker --trace and runs server/run_prompt --jc over it, as
server/tests/test_run_prompt_jc.py does, so the ids and the seam writes are the HOST's
(pl_backend.c, pl_pipeline.c). tok_loop_model.py's prediction must equal the capture or
nothing is written (GEN_TOKLOOP_MODEL_DISAGREES). --check regenerates into scratch and
compares with the committed file (GEN_TOKLOOP_CHECK OK|STALE). Scratch: ~/regress_scratch.
NO HARDWARE.
"""
import argparse, os, signal, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools"))
import tok_loop_model as M  # noqa: E402

SERVER = os.path.join(REPO, "server")
RUN_PROMPT = os.path.join(SERVER, "run_prompt")
BROKER = os.path.join(SERVER, "jc_sim_broker")
MAN_A = os.path.join(SERVER, "tests", "fixtures", "jc27b_die_a_hbm.json")
MAN_B = os.path.join(SERVER, "tests", "fixtures", "jc27b_die_b_hbm.json")
N_EMBD = 4096            # server/fk33_sim.c:183 (jc_sim_broker opens every die with the defaults)
OUT = os.path.join(REPO, "sim", "tok_loop_vec.txt")

# (name, prompt, max_new, stop, pair, mv4i): stop None = "the first id of case a, at
# index >= 1, that has not occurred before it" (a stop that ends the run early).
# mv4i "SYN4096" = the Task 3 synthetic image (tools/jc/gen_embed_gather_vec.py --k 4096),
# prompt ids below its M = 96 and max_new 1, so no generated id is ever gathered.
CASES = [
    ("a", [1, 2, 3], 5, -1, False, None),
    ("b", [1, 2, 3], 5, None, False, None),
    ("c", [7], 1, -1, False, None),
    ("d", [5, 6, 7, 8, 9, 10, 11, 12], 3, -1, False, None),
    ("pa", [1, 2, 3], 5, -1, True, None),
    ("e", [0, 47, 95, 50, 51, 61], 1, -1, False, "SYN4096"),
]
GATHER_VEC = os.path.join(REPO, "sim", "embed_gather_k4096_vec.txt")


def syn_mv4i(base):
    """Rebuild the Task 3 image; refuse unless its vectors equal the committed ones, which is
    what makes tb_tok_loop_top's poked image the image these ids were computed from."""
    d = tempfile.mkdtemp(prefix="tlv_mv4i_", dir=base)
    img, vec = os.path.join(d, "syn.mv4i"), os.path.join(d, "eg.txt")
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_embed_gather_vec.py"), "--k", "4096",
                        "--out", vec, "--mv4i", img], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL gather image\n" + r.stdout + r.stderr)
    if open(vec).read() != open(GATHER_VEC).read():
        sys.exit("GEN_TOKLOOP_FAIL the synthetic image differs from %s: regenerate Task 3 first" % GATHER_VEC)
    return img


def write_programs(work):
    """The same descriptor programs as server/tests/test_run_prompt_jc.py's fixture."""
    with open(os.path.join(work, "a.dtbl"), "w") as f:
        for k in range(4):
            for w in range(8):
                f.write("%016x\n" % (0x1000 * k + w + 1))
    with open(os.path.join(work, "a.rel"), "w") as f:
        for k in range(4):
            f.write(format(k + 1, "032b") + "\n")
    with open(os.path.join(work, "b.dtbl"), "w") as f:
        for k in range(3):
            for w in range(8):
                f.write("%016x\n" % (0x2000 * k + w + 7))
    with open(os.path.join(work, "b.rel"), "w") as f:
        for k in range(3):
            f.write(format(k + 9, "032b") + "\n")


def run_case(work, prompt, max_new, stop, pair, mv4i):
    sock = os.path.join(work, "b.sock")
    trace = os.path.join(work, "trace.txt")
    b = subprocess.Popen([BROKER, sock, os.path.join(work, "broker.log"), "--kv-maxpos", "16384",
                          "--dies", "A,B", "--trace", trace],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = b.stdout.readline()
    if not line.startswith("JCSIMBROKER_READY"):
        sys.exit("GEN_TOKLOOP_FAIL broker: %s %s" % (line, b.stderr.read()))
    with open(os.path.join(work, "p.txt"), "w") as f:
        f.write(" ".join(str(x) for x in prompt) + "\n")
    args = [RUN_PROMPT, "--jc", sock, "--jc-die", "A", "--prompt", "p.txt", "--v2", "--seq-reset",
            "--dtbl", "a.dtbl", "--rel", "a.rel", "--manifest", MAN_A,
            "--max-new", str(max_new), "--stop", str(stop), "--ids-out", "ids.txt"]
    if pair:
        args += ["--jc-die2", "B", "--dtbl2", "b.dtbl", "--rel2", "b.rel", "--manifest2", MAN_B]
    if mv4i:
        args += ["--mv4i", mv4i]
    r = subprocess.run(args, cwd=work, capture_output=True, text=True, timeout=900)
    b.send_signal(signal.SIGTERM)
    b.wait(timeout=10)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL run_prompt rc=%d\n%s%s" % (r.returncode, r.stdout, r.stderr))
    ids = [int(l) for l in open(os.path.join(work, "ids.txt")) if l.strip() and not l.startswith("#")]
    return ids, open(trace).read().splitlines()


def row_fn_for(mv4i):
    if not mv4i:
        return lambda tok: M.synth_row(tok, N_EMBD)
    import embed_gather as EG
    pt = EG.PackedTensor(mv4i)
    return lambda tok: pt.row_bfp(tok, recipe=EG.RECIPE_WIDE)


def first_diff(a, b):
    for k in range(max(len(a), len(b))):
        x = a[k] if k < len(a) else None
        y = b[k] if k < len(b) else None
        if x != y:
            return k, x, y
    return None


def generate(path):
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    out = ["# sim/tok_loop_vec.txt -- GENERATED by tools/jc/gen_tok_loop_vec.py; do not hand-edit.",
           "# C plen max_new stop n_ids kind(0 single 1 pair 2 gather) / P prompt / I ids / W die off val / D die n fnv / E",
           "# ids and writes are run_prompt's over server/jc_sim_broker (the fk33_sim seam)."]
    ids_a = None
    syn = None
    for name, prompt, max_new, stop, pair, mv4i in CASES:
        if mv4i == "SYN4096":
            syn = syn or syn_mv4i(base)
            mv4i = syn
        if stop is None:
            k = next(k for k in range(1, len(ids_a)) if ids_a[k] not in ids_a[:k])
            stop = ids_a[k]
        work = tempfile.mkdtemp(prefix="tlv_%s_" % name, dir=base)
        write_programs(work)
        ids, lines = run_case(work, prompt, max_new, stop, pair, mv4i)
        if name == "a":
            ids_a = ids
        row = row_fn_for(mv4i)
        rows = [row(t) for t in M.fed_tokens(prompt, ids)]
        got = {"A": M.parse_trace(lines, "A")}
        want = {"A": M.die_writes(rows, role="A" if pair else "single")}
        if pair:
            got["B"] = M.parse_trace(lines, "B")
            want["B"] = M.die_writes(rows)       # the sim hop is the identity (fk33_sim.c:418-430)
        for die in got:
            dif = first_diff(got[die], want[die])
            if dif is not None:
                sys.exit("GEN_TOKLOOP_MODEL_DISAGREES case %s die %s op %d: capture %r model %r"
                         % (name, die, dif[0], dif[1], dif[2]))
        kind = 1 if pair else (2 if mv4i else 0)
        out.append("C %d %d %d %d %d" % (len(prompt), max_new, stop, len(ids), kind))
        out.append("P " + " ".join(str(x) for x in prompt))
        out.append("I " + " ".join(str(x) for x in ids))
        for dn, die in enumerate(sorted(got)):
            for op in got[die]:
                if op[0] == "W":
                    out.append("W %d %03X %08X" % (dn, op[1], op[2]))
                else:
                    out.append("D %d %d %08X" % (dn, op[1], op[2]))
        out.append("E")
        print("GEN_TOKLOOP case %s: %d prompt, %d ids, %s ops" %
              (name, len(prompt), len(ids), "+".join(str(len(got[d])) for d in sorted(got))))
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    r = subprocess.run(["make", "-C", SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("GEN_TOKLOOP_FAIL make\n" + r.stdout + r.stderr)
    if a.check:
        tmp = os.path.join(tempfile.mkdtemp(prefix="tlv_check_", dir=os.path.expanduser("~/regress_scratch")),
                           "tok_loop_vec.txt")
        generate(tmp)
        same = open(tmp).read() == open(a.out).read()
        print("GEN_TOKLOOP_CHECK %s" % ("OK" if same else "STALE"))
        return 0 if same else 1
    generate(a.out)
    print("GEN_TOKLOOP_DONE %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
