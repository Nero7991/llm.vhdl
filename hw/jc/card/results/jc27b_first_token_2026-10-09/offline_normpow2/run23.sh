#!/bin/bash
cd /home/orencollaco/regress_scratch/jc27b_gain/work
T=$(cat toks23.txt)
A=img_qwen38-27b-card0-b0-32; B=img_qwen38-27b-card1-b33-63
./run27b --packed $A --tokens $T --x-in emb_prompt23.txt --layers 33 --x-out x23A_ok.txt > r23A_ok.log 2>&1 &
./run27b --packed $A --tokens $T --x-in emb_prompt23.txt --layers 33 --norm-pow2 --x-out x23A_p2.txt > r23A_p2.log 2>&1 &
wait
./run27b --packed $B --tokens $T --x-in x23A_ok.txt --first 33 --layers 64 --top 10 --x-out x23B_ok.txt > r23B_ok.log 2>&1 &
./run27b --packed $B --tokens $T --x-in x23A_p2.txt --first 33 --layers 64 --norm-pow2 --top 10 --x-out x23B_p2.txt > r23B_p2.log 2>&1 &
wait
echo RUN23_DONE > run23.done
