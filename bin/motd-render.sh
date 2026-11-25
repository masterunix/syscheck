#!/usr/bin/env bash
# Renders the login banner from state.json. Writes to stdout; run.sh captures
# it into /var/lib/syscheck/motd, which /etc/update-motd.d/99-syscheck cats.
# Kept dependency-light and fast: this runs on every single SSH login.
set -uo pipefail
SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

[ -f "$SC_STATE" ] || { exit 0; }

phase=$(sc_json_get "$SC_STATE" phase)
sev=$(sc_json_get "$SC_STATE" severity)
msg=$(sc_json_get "$SC_STATE" message)
started_clock=$(sc_json_get "$SC_STATE" started_clock)
updated_clock=$(sc_json_get "$SC_STATE" updated_clock)
date_s=$(sc_json_get "$SC_STATE" date)
run_dir=$(sc_json_get "$SC_STATE" run_dir)
source=$(sc_json_get "$SC_STATE" verdict_source)

# The message can come from Claude, which read attacker-influenced logs. Strip
# control characters so it cannot carry terminal escape sequences to a login.
msg=$(printf '%s' "$msg" | tr -d '\000-\010\013-\037\177')
note=""
[ -r "$SC_ETC/note" ] && note=$(head -1 "$SC_ETC/note" | tr -d '\000-\037\177' | cut -c1-300)

# Colour only when the login is a real terminal.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  R=""; B=""; DIM=""; GRN=""; YEL=""; RED=""; CYN=""
fi

case "$sev" in
  none)     C="$GRN"; label="None" ;;
  minor)    C="$YEL"; label="Minor issue" ;;
  major)    C="$YEL"; label="Needs attention" ;;
  critical) C="$RED"; label="CRITICAL" ;;
  *)        C="$DIM"; label="Unknown" ;;
esac

# --- the status line, phrased the way it reads at a glance ---------------
case "$phase" in
  running)
    if [ "$sev" = "none" ]; then
      status="In progress (started ${started_clock}), no faults found yet"
    else
      status="In progress (started ${started_clock}), ${C}faults found${R}"
    fi
    ;;
  analyzing)
    if [ "$sev" = "none" ]; then
      status="In progress (started ${started_clock}), Claude is reviewing, no faults yet"
    else
      status="In progress (started ${started_clock}), Claude is investigating ${C}faults${R}"
    fi
    ;;
  complete)
    case "$sev" in
      none)     status="${GRN}Completed${R} ${updated_clock}, ${date_s} - no faults" ;;
      minor)    status="${YEL}Completed${R} ${updated_clock}, ${date_s} - minor issues found" ;;
      major)    status="${YEL}Completed${R} ${updated_clock}, ${date_s} - faults found" ;;
      critical) status="${RED}Completed${R} ${updated_clock}, ${date_s} - ${RED}${B}CRITICAL faults found${R}" ;;
    esac
    ;;
  failed)   status="${RED}Did not complete${R} (${updated_clock}) - the check itself failed" ;;
  timeout)  status="${YEL}Timed out${R} (${updated_clock}) - analysis was cut short; collected data is intact" ;;
  stopped)  status="${YEL}Stopped${R} (${updated_clock}, ${date_s}) - interrupted before it finished" ;;
  *)        status="${DIM}No run recorded yet${R}" ;;
esac

W=76
hr() { printf '%s\n' "${DIM}$(printf '─%.0s' $(seq 1 $W))${R}"; }

echo
hr
printf ' %-28s %s\n' "System Check" ": $status"
printf ' %-28s %s\n' "Severity"     ": ${C}${label}${R}"
# Print a long value under a label, wrapped to the banner width.
wrap() {  # wrap <label> <text>
  printf '%s\n' "$2" | fold -s -w $(( W - 32 )) | \
    awk -v pre="$(printf ' %-28s : ' "$1")" -v ind="                                " \
        'NR==1{print pre $0; next}{print ind $0}'
}
if [ -n "$msg" ]; then
  if [ "$source" = "claude" ]; then wrap "Claude Message" "$msg"; else wrap "Message" "$msg"; fi
fi
# The owner's own line, set with `syscheck note "..."`.
[ -n "$note" ] && wrap "Note" "$note"
# --- usage accounting ---------------------------------------------------
# Read from the persistent ledger, not the run directories, so month totals
# stay correct after the 45-run prune.
LEDGER="$SC_VAR/usage.tsv"
# Shown once Claude has been used at least once this month.
if [ -r "$LEDGER" ] && awk -F'\t' -v mon="$(date +%Y-%m)" 'NR>1 && substr($1,1,7)==mon && $3>0 {f=1} END{exit !f}' "$LEDGER"; then
  read -r n_tok n_kb m_tok m_kb m_cost m_runs <<<"$(
    awk -F'\t' -v mon="$(date +%Y-%m)" '
      NR==1 { next }
      {
        last_tok=$3; last_bytes=$8
        if (substr($1,1,7) == mon) { mt+=$3; mb+=$8; mc+=$7; mr++ }
      }
      END {
        printf "%d %d %d %d %.2f %d",
          last_tok, last_bytes/1024, mt, mb/1024, mc, mr
      }' "$LEDGER"
  )"

  fmt() {  # thousands separators, portable
    printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
  }
  hkb() {  # KB -> KB/MB
    if [ "${1:-0}" -ge 1024 ]; then awk -v k="$1" 'BEGIN{printf "%.1f MB", k/1024}'
    else printf '%s KB' "${1:-0}"; fi
  }

  echo
  printf ' %-28s %s\n' "Token Usage Last Run"          ": $(fmt "${n_tok:-0}") tokens"
  printf ' %-28s %s\n' "Token Usage Last Run (KBs)"    ": $(hkb "${n_kb:-0}")"
  printf ' %-28s %s\n' "Token Usage This Month"        ": $(fmt "${m_tok:-0}") tokens  ${DIM}(${m_runs:-0} run$([ "${m_runs:-0}" = "1" ] || echo s), \$${m_cost:-0.00})${R}"
  printf ' %-28s %s\n' "Token Usage This Month (KBs)"  ": $(hkb "${m_kb:-0}")"
fi

if [ -n "$run_dir" ] && [ "$phase" = "complete" ]; then
  if [ -f "$run_dir/report.md" ]; then printf ' %-28s %s\n' "Full report" ": ${CYN}${run_dir}/report.md${R}"
  else printf ' %-28s %s\n' "Details" ": ${CYN}syscheck findings${R}"; fi
fi
if [ "$sev" = "critical" ]; then
  printf ' %s\n' "${RED}${B}!! Read that report before you keep using this machine.${R}"
fi
hr
