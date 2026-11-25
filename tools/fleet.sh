#!/usr/bin/env bash
# Look after syscheck on several machines from one workstation, over SSH.
#
#   tools/fleet.sh [status] [host...]   version and latest result on each
#   tools/fleet.sh upgrade [host...]    install or upgrade to the latest release
#   tools/fleet.sh upgrade --force ...  reinstall even where it is up to date
#   tools/fleet.sh run [host...]        start a check now, in the background
#
# A host is anything ssh accepts: an alias from ~/.ssh/config or user@address.
# With no hosts on the command line they come from ~/.config/syscheck/hosts,
# one per line, # for comments. That file stays on this workstation: the
# repository never holds anything about particular machines.
#
# `upgrade` runs the same one-line installer on each machine that you would
# run by hand (get.sh), and asks for that machine's sudo password. A new
# machine joins the fleet by being added to the hosts file and upgraded.
set -uo pipefail
REPO="${SYSCHECK_REPO:-masterunix/syscheck}"
GET="https://github.com/$REPO/releases/latest/download/get.sh"
HOSTS_FILE="${SYSCHECK_HOSTS:-$HOME/.config/syscheck/hosts}"
SSH_OPTS=(-o ConnectTimeout=10)

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd="status"
case "${1:-}" in
  status|upgrade|run) cmd="$1"; shift ;;
  -h|--help|help)     usage 0 ;;
  -*)                 [ "$1" = "--force" ] || usage 2 ;;
esac
FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

hosts=()
if [ $# -gt 0 ]; then
  hosts=("$@")
elif [ -f "$HOSTS_FILE" ]; then
  while read -r h _; do
    case "$h" in ""|\#*) continue ;; esac
    hosts+=("$h")
  done < "$HOSTS_FILE"
fi
if [ ${#hosts[@]} -eq 0 ]; then
  echo "no hosts: name them on the command line, or list them in $HOSTS_FILE (one per line)" >&2
  exit 2
fi

# The newest release, from the same file get.sh reads.
latest="$(curl -fsSL --max-time 20 "https://github.com/$REPO/releases/latest/download/SHA256SUMS" 2>/dev/null \
  | grep -oE 'syscheck-[0-9][0-9A-Za-z.+-]*\.tar\.gz' | head -1 | sed 's/^syscheck-//; s/\.tar\.gz$//')"

# What each machine reports: version, phase, severity, last update, message.
# 0.1 installs have no VERSION file.
REMOTE_STATUS='
v=$(cat /opt/syscheck/VERSION 2>/dev/null) || { if [ -d /opt/syscheck ]; then v=0.1; else v=none; fi; }
s=/var/lib/syscheck/state.json
if [ -r "$s" ] && command -v jq >/dev/null; then
  jq -r --arg v "$v" "[\$v, .phase, .severity, .updated, .message] | map(. // \"-\" | tostring | gsub(\"[\\t\\n]\"; \" \")) | @tsv" "$s"
else
  printf "%s\t-\t-\t-\t-\n" "$v"
fi'

# on <host> <script>: run a bash script there without prompting, whatever the
# account's login shell is.
on() { printf '%s\n' "$2" | ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$1" 'bash -s' 2>/dev/null; }

remote_version() {  # remote_version <host>  -> version, "none", or empty if unreachable
  on "$1" 'cat /opt/syscheck/VERSION 2>/dev/null || { [ -d /opt/syscheck ] && echo 0.1 || echo none; }' | head -1
}

status() {
  echo "latest release: ${latest:-unknown (GitHub not reachable)}"
  printf '%-26s %-16s %-9s %-9s %-17s %s\n' HOST VERSION PHASE SEVERITY UPDATED MESSAGE
  local h line v phase sev upd msg mark
  for h in "${hosts[@]}"; do
    line="$(on "$h" "$REMOTE_STATUS" | head -1)"
    if [ -z "$line" ]; then printf '%-26s %s\n' "$h" "unreachable"; continue; fi
    IFS=$'\t' read -r v phase sev upd msg <<<"$line"
    [ ${#msg} -gt 60 ] && msg="${msg:0:57}..."
    mark=""; [ -n "$latest" ] && [ "$v" != "$latest" ] && mark=" (upgrade)"
    printf '%-26s %-16s %-9s %-9s %-17s %s\n' "$h" "$v$mark" "$phase" "$sev" "${upd:0:16}" "$msg"
  done
}

upgrade() {
  local h v ok=() skipped=() failed=()
  for h in "${hosts[@]}"; do
    v="$(remote_version "$h")"
    if [ -z "$v" ]; then echo "==> $h: unreachable"; failed+=("$h"); continue; fi
    if [ "$FORCE" = "0" ] && [ -n "$latest" ] && [ "$v" = "$latest" ]; then
      echo "==> $h: already $v"; skipped+=("$h"); continue
    fi
    echo; echo "==> $h: $v -> ${latest:-latest} (asks for the sudo password on $h)"
    if ssh -t "${SSH_OPTS[@]}" "$h" "curl -fsSL '$GET' | sudo bash"; then ok+=("$h"); else failed+=("$h"); fi
  done
  echo
  [ ${#ok[@]} -gt 0 ]      && echo "upgraded: ${ok[*]}"
  [ ${#skipped[@]} -gt 0 ] && echo "up to date: ${skipped[*]}"
  [ ${#failed[@]} -gt 0 ]  && echo "FAILED or reported failed checks: ${failed[*]} (see above)"
  echo; status
  [ ${#failed[@]} -eq 0 ]
}

run() {
  local h out rc=0
  for h in "${hosts[@]}"; do
    # The sudoers grant syscheck installs covers run.sh, so no password. nohup:
    # the run must outlive this SSH session.
    out="$(on "$h" '
      sudo -n -l /opt/syscheck/bin/run.sh >/dev/null 2>&1 || { echo "no sudo grant for run.sh (is syscheck installed?)"; exit 1; }
      nohup sudo -n /opt/syscheck/bin/run.sh </dev/null >/dev/null 2>&1 &
      sleep 2
      pgrep -f "^bash /opt/syscheck/bin/run.sh" >/dev/null && echo "running" || { echo "did not start"; exit 1; }')" || rc=1
    printf '%-26s %s\n' "$h" "${out:-unreachable}"
  done
  echo "follow with: tools/fleet.sh status"
  return "$rc"
}

"$cmd"
