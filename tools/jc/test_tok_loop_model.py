"""tools/jc/tok_loop_model.py against a capture of run_prompt (plan 2026-11-04 Task 2).
    python3 -m pytest -q tools/jc/test_tok_loop_model.py
NO HARDWARE: server/jc_sim_broker over the fk33_sim seam."""
import os, subprocess, sys, tempfile
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tok_loop_model as M          # noqa: E402
import gen_tok_loop_vec as G        # noqa: E402


@pytest.fixture(scope="module")
def capture():
    r = subprocess.run(["make", "-C", G.SERVER, "run_prompt", "jc_sim_broker"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    base = os.path.expanduser("~/regress_scratch")
    os.makedirs(base, exist_ok=True)
    work = tempfile.mkdtemp(prefix="tlm_", dir=base)
    G.write_programs(work)
    ids, lines = G.run_case(work, [1, 2, 3], 4, -1, False, None)
    return ids, lines


def rows(prompt, ids):
    return [M.synth_row(t, G.N_EMBD) for t in M.fed_tokens(prompt, ids)]


def test_model_equals_the_host_capture(capture):
    ids, lines = capture
    assert len(ids) == 4
    assert M.parse_trace(lines, "A") == M.die_writes(rows([1, 2, 3], ids))


def test_teeth_prompt_index_off_by_one(capture):
    ids, lines = capture
    shifted = [M.synth_row(t, G.N_EMBD) for t in ([2, 3] + ids[:1] + ids[:-1])][:len(rows([1, 2, 3], ids))]
    assert M.parse_trace(lines, "A") != M.die_writes(shifted)


def test_teeth_no_seq_reset(capture):
    ids, lines = capture
    assert M.parse_trace(lines, "A") != M.die_writes(rows([1, 2, 3], ids))[1:]


def test_teeth_synth_row_exponent(capture):
    ids, lines = capture
    bad = [(m, e + 1) for m, e in rows([1, 2, 3], ids)]
    assert M.parse_trace(lines, "A") != M.die_writes(bad)
