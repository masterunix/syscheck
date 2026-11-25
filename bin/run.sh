#!/usr/bin/env bash
# Orchestrator. Runs as root from syscheck.timer (daily, 05:00 by default).
#
#   collect -> rule-based verdict -> Claude analysis -> final verdict -> MOTD
#
# Every stage updates state.json, so an SSH login mid-run shows live status.
# An EXIT trap guarantees the banner never gets stranded on "In progress".
set -uo pipefail

SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

# Nothing in a run reads input. Started from a terminal (`syscheck run`), stdin
# would be that terminal, while every probe and the Claude CLI run under
# `timeout`, which puts them in a process group of their own. A program that
# touches the terminal from there is stopped by the kernel, together with the
# `timeout` meant to kill it, and the run hangs for good. The Claude CLI does.
exec </dev/null

export SC_PREFIX
SC_STARTED="$(sc_now)"
SC_STARTED_CLOCK="$(sc_clock)"
export SC_STARTED SC_STARTED_CLOCK

# --no-analysis: collect and apply the rules, skip Claude (syscheck collect).
NO_ANALYSIS=0
[ "${1:-}" = "--no-analysis" ] && NO_ANALYSIS=1
[ "${SC_ANALYSIS:-on}" = "off" ] && NO_ANALYSIS=1

RUN_ID="$(date '+%Y-%m-%d_%H%M%S')"
SC_RUN_DIR="$SC_RUNS/$RUN_ID"
export SC_RUN_DIR
mkdir -p "$SC_RUN_DIR" "$SC_VAR"

# Collection runs as root, but the analysis stage runs as the desktop user and
# has to create report.md and verdict.json in here. Group-own the directory to
# that user and set the setgid bit so anything root writes stays group-readable.
if [ "$(id -u)" = "0" ] && id "$SC_USER" >/dev/null 2>&1; then
  chown root:"$SC_USER" "$SC_RUN_DIR" 2>/dev/null
  chmod 2770 "$SC_RUN_DIR" 2>/dev/null
fi
# Everything above the run directory stays root-only for writing. The analysis
# account must never be able to plant a symlink where root later writes.
chmod 0755 "$SC_VAR" "$SC_RUNS" 2>/dev/null
chown root:root "$SC_VAR" "$SC_RUNS" 2>/dev/null

# Single-instance lock: a hung run must not stack up behind tomorrow's.
exec 9>"$SC_VAR/run.lock"
if ! flock -n 9; then
  echo "another syscheck run is already in progress; exiting" >&2
  exit 0
fi

FINALIZED=0
STOPPED_BY=""
finalize_failure() {
  [ "$FINALIZED" = "1" ] && return 0
  if [ -n "$STOPPED_BY" ]; then
    sc_state_write "stopped" "${RULE_SEV:-unknown}" \
      "The check was stopped before it finished${RULE_SUMMARY:+. Rules so far: $RULE_SUMMARY}"
    sc_log "run stopped by SIG$STOPPED_BY"
  else
    sc_state_write "failed" "major" \
      "The nightly system check did not finish. Collected data is in $SC_RUN_DIR — check 00-run.log."
    sc_log "run aborted before completion"
  fi
}
trap finalize_failure EXIT

# Ctrl-C, `systemctl stop`, a dropped SSH session. `timeout` keeps the
# terminal's Ctrl-C from reaching what it runs, so the long stages run in the
# background where `wait` can be interrupted, and a signal stops every process
# this run started, parents first so nothing spawns a replacement.
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
on_signal() {
  trap - INT TERM HUP
  STOPPED_BY="$1"
  local pids; pids="$(descendants $$)"
  # shellcheck disable=SC2086
  [ -n "$pids" ] && kill -TERM $pids 2>/dev/null
  exit 130
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# ---------------------------------------------------------------- stage 1
sc_state_write "running" "none" ""
sc_log "=== syscheck run $RUN_ID starting ==="
sc_log "stage 1/4: collecting"

# collect.sh logs each line to 00-run.log itself; keep only its errors here.
"$SC_PREFIX/bin/collect.sh" > /dev/null 2>> "$SC_RUN_DIR/00-run.log" &
wait $!
sc_log "stage 1 finished (rc=$?)"

# ---------------------------------------------------------------- stage 2
# Deterministic verdict first, so the banner is already truthful before Claude
# has said a word — and stays truthful if Claude never finishes.
sc_log "stage 2/4: rule-based verdict"
IFS=$'\t' read -r RULE_SEV RULE_IMMINENT RULE_SUMMARY < <("$SC_PREFIX/bin/verdict.sh")
sc_log "rules say: severity=$RULE_SEV imminent=$RULE_IMMINENT — $RULE_SUMMARY"
printf '%s\t%s\t%s\n' "$RULE_SEV" "$RULE_IMMINENT" "$RULE_SUMMARY" > "$SC_RUN_DIR/rule-verdict.tsv"

ln -sfn "$SC_RUN_DIR" "$SC_LATEST"

sc_state_write "analyzing" "$RULE_SEV" \
  "Collection finished. Claude is reviewing the results now."

# A drive failing this hard should not wait for an LLM to agree.
if [ "${RULE_IMMINENT:-0}" -gt 0 ] && [ "${SC_ALARM:-on}" = "on" ]; then
  sc_log "rules flagged an IMMINENT fault — sounding the alarm without waiting for Claude"
  # 9>&-: the alarm outlives the run and must not keep holding its lock.
  "$SC_PREFIX/bin/alarm.sh" start "${SC_ALARM_SECONDS:-600}" >> "$SC_RUN_DIR/00-run.log" 2>&1 9>&- &
fi

# ---------------------------------------------------------------- stage 3
CLAUDE_RC=0
if [ "$NO_ANALYSIS" = "1" ]; then
  sc_log "stage 3/4: skipped (analysis is off for this run)"
else
  sc_log "stage 3/4: Claude analysis (hard timeout ${SC_CLAUDE_TIMEOUT:-3600}s)"
  "$SC_PREFIX/bin/analyze.sh" >> "$SC_RUN_DIR/00-run.log" 2>&1 9>&- &
  wait $! || CLAUDE_RC=$?
fi
[ -f "$SC_RUN_DIR/claude-stats.txt" ] && sc_log "claude: $(head -1 "$SC_RUN_DIR/claude-stats.txt")"
sc_log "stage 3 finished (rc=$CLAUDE_RC)"

# ---------------------------------------------------------------- stage 4
# The analysis account is done writing. Take the directory back before root
# touches it again, and drop anything it may have linked elsewhere.
if [ "$(id -u)" = "0" ]; then
  chmod 2750 "$SC_RUN_DIR" 2>/dev/null
  find "$SC_RUN_DIR" -type l -delete 2>/dev/null
fi
sc_log "stage 4/4: final verdict"
V="$SC_RUN_DIR/verdict.json"
FINAL_SEV="$RULE_SEV"
FINAL_IMMINENT="$RULE_IMMINENT"
FINAL_MSG="$RULE_SUMMARY"
PHASE="complete"
SOURCE="rules"

if [ -s "$V" ]; then
  c_sev=$(sc_json_get "$V" severity)
  c_msg=$(sc_json_get "$V" motd_message)
  c_imm=$(jq -r '.imminent_failure // false' "$V" 2>/dev/null)
  if [ -n "$c_sev" ] && [ -n "$c_msg" ]; then
    FINAL_SEV="$c_sev"
    FINAL_MSG="$c_msg"
    SOURCE="claude"
    # Claude may downgrade severity with context, but it can never talk the
    # rules out of an imminent-failure flag — only add to it.
    [ "$c_imm" = "true" ] && FINAL_IMMINENT=1
    sc_log "claude verdict: severity=$c_sev imminent=$c_imm"
  else
    sc_log "verdict.json present but unparseable; keeping the rule-based verdict"
  fi
else
  sc_log "no verdict.json from claude (rc=$CLAUDE_RC); keeping the rule-based verdict"
  if [ "$NO_ANALYSIS" = "1" ]; then
    :
  elif [ -s "$SC_RUN_DIR/claude-problem.txt" ]; then
    FINAL_MSG="$RULE_SUMMARY — $(head -1 "$SC_RUN_DIR/claude-problem.txt")"
  elif [ "$CLAUDE_RC" = "124" ] || [ "$CLAUDE_RC" = "137" ]; then
    PHASE="timeout"
    FINAL_MSG="$RULE_SUMMARY — Claude's review timed out; this is the automated read only."
  elif [ "$CLAUDE_RC" != "0" ]; then
    FINAL_MSG="$RULE_SUMMARY — Claude's review failed to run; this is the automated read only."
  fi
fi

# Alarm on Claude's call, if the rules had not already fired.
if [ "${FINAL_IMMINENT:-0}" -gt 0 ] && [ "${RULE_IMMINENT:-0}" -eq 0 ] && [ "${SC_ALARM:-on}" = "on" ]; then
  sc_log "claude flagged IMMINENT failure — sounding the alarm"
  "$SC_PREFIX/bin/alarm.sh" start "${SC_ALARM_SECONDS:-600}" >> "$SC_RUN_DIR/00-run.log" 2>&1 9>&- &
fi

# --- usage ledger -------------------------------------------------------
# Token and cost accounting lives outside the run directories so month totals
# survive the 45-run prune. One row per run, appended forever (~70 bytes/night,
# so about 25 KB a year).
record_usage() {
  local j="$SC_RUN_DIR/claude-output.json"
  local tin=0 tcache=0 tread=0 tout=0 cost=0
  if [ -s "$j" ] && command -v jq >/dev/null; then
    tin=$(jq -r '.usage.input_tokens // 0'                 "$j" 2>/dev/null)
    tcache=$(jq -r '.usage.cache_creation_input_tokens // 0' "$j" 2>/dev/null)
    tread=$(jq -r '.usage.cache_read_input_tokens // 0'    "$j" 2>/dev/null)
    tout=$(jq -r '.usage.output_tokens // 0'               "$j" 2>/dev/null)
    cost=$(jq -r '.total_cost_usd // 0'                    "$j" 2>/dev/null)
  fi
  # Bytes of the capped views -- the material actually put in front of Claude.
  local logb
  logb=$(cat "$SC_RUN_DIR"/*.log "$SC_RUN_DIR"/*.txt "$SC_RUN_DIR"/*.tsv 2>/dev/null | wc -c)
  local total=$(( tin + tcache + tread + tout ))

  local led="$SC_VAR/usage.tsv"
  [ -f "$led" ] || printf 'date\tepoch\ttokens_total\ttokens_new\ttokens_cached\ttokens_out\tcost_usd\tlog_bytes\n' > "$led"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%F)" "$(date +%s)" "$total" "$(( tin + tcache ))" "$tread" "$tout" "$cost" "$logb" >> "$led"
  chmod 644 "$led" 2>/dev/null
  sc_log "usage: $total tokens, \$$cost, $(( logb / 1024 ))KB of logs"
}
record_usage

FINALIZED=1
sc_state_write "$PHASE" "$FINAL_SEV" "$FINAL_MSG" \
  "  \"verdict_source\": \"$SOURCE\",
  \"imminent\": ${FINAL_IMMINENT:-0},
  \"claude_rc\": $CLAUDE_RC,
  \"run_id\": \"$RUN_ID\""


# Machine-readable record, handy for anything else that wants to consume this.
cp -f "$SC_STATE" "$SC_RUN_DIR/state.json" 2>/dev/null

# ------------------------------------------------------------------ prune
KEEP="${SC_KEEP_RUNS:-45}"
( cd "$SC_RUNS" 2>/dev/null && ls -1d */ 2>/dev/null | sort -r | tail -n +$((KEEP+1)) | \
    while read -r d; do rm -rf "$SC_RUNS/${d%/}"; done ) || true

sc_log "=== run $RUN_ID complete: severity=$FINAL_SEV imminent=${FINAL_IMMINENT:-0} source=$SOURCE ==="
trap - EXIT
exit 0
