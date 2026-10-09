# CPU reference for the JC 27B first-token check (2026-10-09)

MEASURED with llama.cpp (`~/GitHub/llama.cpp.upstream/build/bin/llama-server`, CPU only,
`--device none -ngl 0 -c 512 -np 1 -t 24`) on `/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf`,
prompt `hw/fk33/results/goal_dcdc_2026-09-17/prompt_tokens.txt` fed as 23 ids through
`/completion` (`n_predict 1, temperature 0, top_k 1, n_probs 5`). Command: runbook
`docs/superpowers/plans/2026-10-09-jc-silicon-runbook.md` section 4.2.

    REF_ARGMAX 7732 ("While")   logprob -1.0594
    runner-up  5449 ("DC")      logprob -1.3769   (gap 0.318)
    then 1206 ("To") -1.6087, 2064 ("It") -3.1620, 89454 ("Determin") -3.5080

The top-1/top-2 gap is small. The card computes in INT4 with block-float activations,
not ggml's arithmetic, so a card argmax of 5449 is not by itself evidence of a defect:
compare the card's top scores against both.
