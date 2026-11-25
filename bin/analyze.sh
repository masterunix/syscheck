#!/usr/bin/env bash
# Hand the collected logs to Claude. Runs as the desktop user (Claude's auth
# and config live in that user's home), never as root.
#
# Called by run.sh with SC_RUN_DIR exported.
set -uo pipefail
SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

MODEL="${SC_MODEL:-sonnet}"
TIMEOUT="${SC_CLAUDE_TIMEOUT:-3600}"       # hard ceiling: 1 hour, then killed
BUDGET="${SC_MAX_BUDGET_USD:-2.00}"
EFFORT="${SC_EFFORT:-high}"

# Drop to the unprivileged user if root invoked us.
if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid="$SC_UID" --regid="$SC_UID" --init-groups \
    env HOME="$SC_HOME" USER="$SC_USER" \
        XDG_RUNTIME_DIR="/run/user/$SC_UID" \
        PATH="$SC_USER_PATH" \
        SC_PREFIX="$SC_PREFIX" SC_RUN_DIR="$SC_RUN_DIR" \
    "$0" "$@"
fi

command -v claude >/dev/null || {
  echo "Claude Code is not installed for $SC_USER. Run: syscheck claude install" > "$SC_RUN_DIR/claude-problem.txt"
  echo "claude CLI not found in PATH" >&2; exit 127; }

# Every claude call gets /dev/null as stdin. Under `timeout` it runs in a
# background process group, and when it touches a terminal there the kernel
# stops it (and the timeout with it) forever. run.sh does this for the whole
# run; it is repeated here so the script is safe on its own.

# A run that cannot authenticate should say so on the banner, not just fail.
if command -v jq >/dev/null; then
  auth="$(timeout -k 5 30 claude auth status --json </dev/null 2>/dev/null)"; auth_rc=$?
  if [ "$auth_rc" = "124" ] || [ "$auth_rc" = "137" ]; then
    echo "Claude did not answer its login check within 30 seconds. Try: syscheck claude test" > "$SC_RUN_DIR/claude-problem.txt"
    echo "claude auth status timed out" >&2; exit 124
  fi
  if [ "$(printf '%s' "$auth" | jq -r '.loggedIn // false' 2>/dev/null)" != "true" ]; then
    echo "Claude is not logged in for $SC_USER. Run: syscheck claude login" > "$SC_RUN_DIR/claude-problem.txt"
    echo "claude is not logged in" >&2; exit 126
  fi
fi

# --- build the orientation file Claude opens first ----------------------
SUMMARY="$SC_RUN_DIR/SUMMARY.txt"
{
  echo "SYSTEM CHECK — $(date '+%A %d %B %Y, %H:%M %Z')"
  echo "host: $(hostname)   uptime: $(uptime -p 2>/dev/null)"
  echo "run directory: $SC_RUN_DIR"
  echo
  echo "=============================== FINDINGS ==============================="
  if [ -s "$SC_RUN_DIR/findings.tsv" ]; then
    for sev in critical major minor info; do
      awk -F'\t' -v s="$sev" '$1==s {
        printf "  [%-8s] %-10s %s%s\n", toupper($1), $2, $3, ($4=="1" ? "   <<< flagged IMMINENT" : "")
      }' "$SC_RUN_DIR/findings.tsv"
    done
  else
    echo "  (no threshold rule fired — every automated check passed)"
  fi
  echo
  echo "=============================== METRICS ================================"
  [ -s "$SC_RUN_DIR/metrics.tsv" ] && sort "$SC_RUN_DIR/metrics.tsv" | \
    awk -F'\t' '{printf "  %-26s %s\n", $1, $2}'
  echo
  echo "============================ LOGS AVAILABLE ============================"
  ( cd "$SC_RUN_DIR" && ls -1S *.log *.txt *.tsv 2>/dev/null | \
      awk '{printf "  %-34s %s\n", $0, ""}' )
  echo
  echo "  Read 99-trend.log carefully — it is the difference between"
  echo "  'this drive is old' and 'this drive is failing right now'."
  if [ -d "$SC_RUN_DIR/full" ]; then
    echo
    echo "  The NN-*.log files above are CAPPED views. Complete untruncated"
    echo "  output of every probe is in full/*.full.log.gz ($(du -sh "$SC_RUN_DIR/full" 2>/dev/null | cut -f1))."
    echo "  Use zgrep/zcat on it only when a capped view elides something you need."
  fi
  if [ -s "$SC_RUN_DIR/00-command-failures.txt" ]; then
    echo
    echo "  NOTE — these probes timed out and their data is missing or partial:"
    sed 's/^/    /' "$SC_RUN_DIR/00-command-failures.txt"
  fi
} > "$SUMMARY"

# --- run Claude ----------------------------------------------------------
# This machine's own description, which never leaves it. Falls back to an
# automatic summary when the owner has not written one.
MACHINE="$(sed '/^<!--/,/^-->/d' "$SC_ETC/machine.md" 2>/dev/null)"
[ -n "$MACHINE" ] || MACHINE="$("$SC_PREFIX/bin/describe.sh" 2>/dev/null | sed '/^<!--/,/^-->/d')"
TEMPLATE="$(cat "$SC_PREFIX/prompt/analysis.md")"
PROMPT="${TEMPLATE//\{\{MACHINE\}\}/$MACHINE}

The run directory for tonight is: $SC_RUN_DIR
Write report.md and verdict.json into that directory."

cd "$SC_RUN_DIR" || exit 1

# Nothing collected here may reach another machine. The prompt says so, and
# these rules refuse the obvious tools outright. It is a guardrail, not a
# sandbox: Bash is allowed, so the prompt and the read-only account matter too.
DENY=(WebFetch WebSearch Task
      "Bash(ssh:*)" "Bash(scp:*)" "Bash(sftp:*)" "Bash(rsync:*)" "Bash(curl:*)"
      "Bash(wget:*)" "Bash(nc:*)" "Bash(ncat:*)" "Bash(netcat:*)" "Bash(socat:*)"
      "Bash(telnet:*)" "Bash(ftp:*)" "Bash(tailscale:*)" "Bash(git push:*)"
      "Bash(git clone:*)" "Bash(git fetch:*)")
unset SSH_AUTH_SOCK SSH_AGENT_PID

# `dontAsk` never blocks on a permission prompt — anything outside allowedTools
# is refused outright rather than hanging a scheduled run forever.
timeout -k 60 "$TIMEOUT" claude -p "$PROMPT" \
  --model "$MODEL" \
  --effort "$EFFORT" \
  --permission-mode dontAsk \
  --allowedTools "Bash Read Write Grep Glob" \
  --disallowedTools "${DENY[@]}" \
  --add-dir "$SC_RUN_DIR" \
  --add-dir "$SC_VAR" \
  --max-budget-usd "$BUDGET" \
  --output-format json \
  --no-session-persistence \
  < /dev/null > "$SC_RUN_DIR/claude-output.json" 2> "$SC_RUN_DIR/claude-stderr.log"
rc=$?

# Pull the useful bits out of the result envelope for the run log.
if command -v jq >/dev/null && [ -s "$SC_RUN_DIR/claude-output.json" ]; then
  jq -r '"cost=$\((.total_cost_usd // 0) * 10000 | round / 10000)  turns=\(.num_turns // 0)  \(((.duration_ms // 0) / 1000) | round)s  tokens=in:\(.usage.cache_creation_input_tokens // 0)/cached:\(.usage.cache_read_input_tokens // 0)/out:\(.usage.output_tokens // 0)  stop=\(.stop_reason // "?")  denials=\((.permission_denials // []) | length)"' \
    "$SC_RUN_DIR/claude-output.json" 2>/dev/null > "$SC_RUN_DIR/claude-stats.txt"
  jq -r '.result // empty' "$SC_RUN_DIR/claude-output.json" 2>/dev/null \
    > "$SC_RUN_DIR/claude-reply.txt"
  jq -r '(.permission_denials // []) | .[] | "denied: \(.tool_name) \(.tool_input // {} | tostring | .[0:160])"' \
    "$SC_RUN_DIR/claude-output.json" 2>/dev/null >> "$SC_RUN_DIR/claude-stats.txt"
fi

exit $rc
