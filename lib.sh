#!/bin/bash
# Shared helpers for the FN AutoSC API endpoint handlers.
# Installed to /usr/local/lib/fn-api/lib.sh and sourced by every handler.
#
# The request body is a JSON object on stdin; the response is JSON on stdout.
# Every handler answers with {"status":"success",...} or
# {"status":"error","message":"..."} and exits 0 - a non-zero exit is a crash
# and surfaces as HTTP 500.

body=$(cat 2>/dev/null || true)

command -v jq >/dev/null 2>&1 || { echo '{"status":"error","message":"jq is required on the panel"}'; exit 0; }

# ---- JSON helpers --------------------------------------------------------
j()      { printf '%s' "$body" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null | head -1; }
field()  { local v; v=$(j "$1"); printf '%s' "${v:-$2}"; }

# ---- response helpers ----------------------------------------------------
# fail never returns; ok only prints.
fail() { jq -nc --arg m "$1" '{status:"error",message:$m}'; exit 0; }
ok()   { jq -nc --arg m "$1" '{status:"success",message:$m}'; }

# require <field> <var>: read a required field into <var> IN THE CALLER'S SHELL.
# It must never be used inside $( ): fail's `exit` would then only end the
# subshell, the caller would carry on, and the error text itself would be used
# as the value (e.g. the panel would be asked to create an account named
# '{"status":"error",...}').
require() {
    local __v; __v=$(j "$1")
    [ -n "$__v" ] || fail "missing required field: $1"
    printf -v "$2" '%s' "$__v"
}

# require_tool <name>: the panel tool this endpoint drives must be installed.
# The lite edition ships no SSH tooling and no NoobzVPN, and a missing tool must
# be reported as an error rather than returned as "success" with the shell's
# "No such file or directory" text.
require_tool() {
    [ -x "/usr/bin/$1" ] || command -v "$1" >/dev/null 2>&1 || \
        fail "this panel edition does not ship '$1'"
}

# noobz_accounts: the NoobzVPN account list, whichever CLI form is installed.
noobz_accounts() { noobzvpns print-all 2>/dev/null || noobzvpns --info-all-user 2>/dev/null; }

# ---- output helpers ------------------------------------------------------
strip_ansi()  { sed 's/\x1b\[[0-9;]*m//g'; }
json_array()  { printf '%s' "$1" | jq -R -s 'split("\n") | map(select(length>0))'; }

# panel_reason <output>: the panel's own explanation, flattened, for an error
# message. Used when a panel script refuses the operation, so the caller learns
# why instead of only that it did not happen. The explanation is at the end of
# the output (the prompts and the authorization banner come first), so keep the
# tail.
panel_reason() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//' | tail -c 300; }
