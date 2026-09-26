#!/bin/bash
# Shared helpers for the FN AutoSC FN-API endpoint handlers.
# Installed to /usr/local/lib/fn-api/lib.sh and sourced by every handler.
# The request body is a JSON object on stdin; the response is JSON on stdout.

body=$(cat 2>/dev/null || true)

command -v jq >/dev/null 2>&1 || { echo '{"status":"error","message":"jq is required on the panel"}'; exit 0; }

j()      { printf '%s' "$body" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null | head -1; }
field()  { local v; v=$(j "$1"); printf '%s' "${v:-$2}"; }
need()   { local v; v=$(j "$1"); [ -n "$v" ] || fail "missing required field: $1"; printf '%s' "$v"; }
fail()   { jq -nc --arg m "$1" '{status:"error",message:$m}'; exit 0; }
ok()     { jq -nc --arg m "$1" '{status:"success",message:$m}'; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
json_array() { printf '%s' "$1" | jq -R -s 'split("\n") | map(select(length>0))'; }
