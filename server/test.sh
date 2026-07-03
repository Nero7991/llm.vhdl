#!/bin/sh
# server/test.sh — smoke-test the OpenAI-compatible server.
# Usage: sh server/test.sh [host:port]   (default 127.0.0.1:8000)
# Assumes the server is already running (see server/README.md).
set -e
BASE="http://${1:-127.0.0.1:8000}"

echo "== GET /v1/models =="
curl -s "$BASE/v1/models"; echo; echo

echo "== POST /v1/chat/completions (non-stream) =="
curl -s "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"stories260k","messages":[{"role":"user","content":"Once upon a time"}],"max_tokens":48,"temperature":0}'
echo; echo

echo "== POST /v1/chat/completions (stream) =="
curl -sN "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"stories260k","messages":[{"role":"user","content":"Once upon a time"}],"max_tokens":48,"temperature":0,"stream":true}'
echo; echo

echo "== POST /v1/completions (non-stream) =="
curl -s "$BASE/v1/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"stories260k","prompt":"Once upon a time","max_tokens":48,"temperature":0}'
echo; echo

echo "== done =="
