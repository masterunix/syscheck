#!/usr/bin/env bash
# Shared helpers, paths and state handling for syscheck.
# Sourced by every syscheck script. Never executed directly.

SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
SC_ETC="${SC_ETC:-/etc/syscheck}"
SC_VAR="${SC_VAR:-/var/lib/syscheck}"

# Configuration: shipped defaults first, then this machine's own settings.
# The per-host file lives outside the program directory so an upgrade, which
# replaces /opt/syscheck wholesale, can never overwrite or leak it.
[ -f "$SC_PREFIX/etc/syscheck.conf" ] && . "$SC_PREFIX/etc/syscheck.conf"
[ -f "$SC_ETC/syscheck.conf" ]        && . "$SC_ETC/syscheck.conf"

# Paths are fixed after the settings are read, so no setting can move them.
SC_RUNS="$SC_VAR/runs"
SC_STATE="$SC_VAR/state.json"
SC_MOTD="$SC_VAR/motd"
SC_HISTORY="$SC_VAR/history.tsv"
SC_LATEST="$SC_VAR/latest"
SC_VERSION="$(cat "$SC_PREFIX/VERSION" 2>/dev/null || echo dev)"

# The account that owns the Claude login and the audio session. Empty in the
# config means: the first ordinary login account on this machine.
sc_detect_user() {
  getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /(nologin|false)$/ {print $1; exit}'
}
[ -n "${SC_USER:-}" ] || SC_USER="$(sc_detect_user)"
SC_UID="$(id -u "$SC_USER" 2>/dev/null || echo 1000)"
SC_HOME="$(getent passwd "$SC_USER" | cut -d: -f6)"; SC_HOME="${SC_HOME:-/home/$SC_USER}"
# Where that account's Claude Code may live: the official installer, mise, npm.
SC_USER_PATH="$SC_HOME/.local/bin:$SC_HOME/.local/share/mise/shims:$SC_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# The disk to interrogate. Empty means the disk that holds the root filesystem.
# -v drops a btrfs subvolume suffix such as [/@] from the device name.
SC_ROOT_DEV="$(findmnt -nvo SOURCE / 2>/dev/null)"
if [ -z "${SC_DISK:-}" ]; then
  # Walk up from the root filesystem (through LVM, LUKS or RAID) to a disk.
  _pk="$(lsblk -nrso NAME,TYPE "$SC_ROOT_DEV" 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
  SC_DISK="/dev/${_pk:-sda}"; unset _pk
fi
SC_DISK_NAME="$(basename "$SC_DISK")"

# Where the current run writes its logs. Set by run.sh, inherited by children.
SC_RUN_DIR="${SC_RUN_DIR:-}"

sc_now()      { date '+%Y-%m-%d %H:%M:%S'; }
sc_clock()    { date '+%I:%M %p' | sed 's/^0//'; }
sc_datestamp(){ date '+%d %b'; }
sc_epoch()    { date '+%s'; }

sc_log() {
  local msg="[$(sc_now)] $*"
  echo "$msg"
  [ -n "$SC_RUN_DIR" ] && echo "$msg" >> "$SC_RUN_DIR/00-run.log"
  return 0
}

# Two-tier output. Every probe's COMPLETE output is archived under
# $SC_RUN_DIR/full/, and a capped view goes into the module log that Claude
# reads. That keeps the analysis input flat forever while losing nothing from
# the record: when a capped view elides something, it names the full file, and
# Claude can go read it if the finding warrants.
#
# The alternative -- truncating at the command -- throws the evidence away at
# collection time, which is exactly when you cannot yet know what mattered.

sc_full_dir() { mkdir -p "$SC_RUN_DIR/full"; echo "$SC_RUN_DIR/full"; }

# Write one probe's result to both tiers.
sc_emit() {   # sc_emit <logfile> <label> <cmdline> <tmpfile>
  local out="$1" label="$2" cmdline="$3" tmp="$4"
  local name full n keep_head keep_tail elided
  name="$(basename "$out")"
  full="$(sc_full_dir)/${name%.log}.full.log"

  n=$(wc -l < "$tmp" 2>/dev/null || echo 0)

  # --- tier 1: the complete record ---
  {
    echo "### $label"
    echo "\$ $cmdline"
    if [ "$n" -gt "${SC_FULL_MAX_LINES:-20000}" ]; then
      # Even the archive needs a backstop: one runaway probe must not fill a
      # disk that is the only disk in the machine.
      head -"${SC_FULL_MAX_LINES:-20000}" "$tmp"
      echo "!! archive truncated at ${SC_FULL_MAX_LINES:-20000} of $n lines"
    else
      cat "$tmp"
    fi
    echo
  } >> "$full"

  # --- tier 2: the capped view Claude reads ---
  {
    echo "### $label"
    echo "\$ $cmdline"
    if [ "$n" -le "${SC_LOG_MAX_LINES:-120}" ]; then
      cat "$tmp"
    else
      keep_head="${SC_LOG_HEAD:-40}"
      keep_tail="${SC_LOG_TAIL:-60}"
      elided=$(( n - keep_head - keep_tail ))
      head -"$keep_head" "$tmp"
      echo "    [ ... $elided of $n lines elided — full output: full/${name%.log}.full.log ... ]"
      tail -"$keep_tail" "$tmp"
    fi
    echo
  } >> "$out"
  return 0
}

# run <logfile> <label> -- <command...>
# Executes a command with a timeout and never lets a failure abort the caller.
# Aging hardware makes commands hang; the timeout is the whole point.
sc_run() {
  local out="$1"; shift
  local label="$1"; shift
  [ "$1" = "--" ] && shift
  local tmo="${SC_CMD_TIMEOUT:-25}"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/syscheck.XXXXXX")"
  local rc=0
  timeout -k 5 "$tmo" "$@" > "$tmp" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "!! TIMED OUT after ${tmo}s" >> "$tmp"
    echo "timeout:$label" >> "$SC_RUN_DIR/00-command-failures.txt"
  elif [ "$rc" -ne 0 ]; then
    echo "!! exited rc=$rc" >> "$tmp"
  fi
  sc_emit "$out" "$label" "$*" "$tmp"
  rm -f "$tmp"
  return 0
}

# Same, but the command is a shell snippet (pipes, redirects, globs).
sc_sh() {
  local out="$1" label="$2" snippet="$3"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/syscheck.XXXXXX")"
  local rc=0
  timeout -k 5 "${SC_CMD_TIMEOUT:-25}" bash -c "$snippet" > "$tmp" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "!! TIMED OUT" >> "$tmp"
    echo "timeout:$label" >> "$SC_RUN_DIR/00-command-failures.txt"
  elif [ "$rc" -ne 0 ]; then
    echo "!! exited rc=$rc" >> "$tmp"
  fi
  sc_emit "$out" "$label" "$snippet" "$tmp"
  rm -f "$tmp"
  return 0
}

# --- metric capture -----------------------------------------------------
# Numeric metrics get recorded flat so we can diff tonight against last night.
# Trend is the whole game on hardware this old: a single reallocated sector is
# noise, four more of them since yesterday is a dying drive.
# Normalise anything into a plain integer. Guards against the classic
# `grep -c ... || echo 0` trap, where grep prints "0" AND exits 1, so the
# fallback appends a second zero and every later [ -gt ] test blows up.
sc_num() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr -d '[:space:]' | grep -oE '^[0-9]+' | head -1)"
  printf '%s' "${v:-0}"
}

sc_metric() {
  local key="$1" val="$2"
  [ -z "$SC_RUN_DIR" ] && return 0
  printf '%s\t%s\n' "$key" "$val" >> "$SC_RUN_DIR/metrics.tsv"
  return 0
}

sc_metric_get() {   # sc_metric_get <run_dir> <key>
  awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1/metrics.tsv" 2>/dev/null
}

sc_prev_run_dir() {  # newest completed run that is not the current one
  local d
  for d in $(ls -1d "$SC_RUNS"/*/ 2>/dev/null | sort -r); do
    d="${d%/}"
    [ "$d" = "$SC_RUN_DIR" ] && continue
    [ -f "$d/metrics.tsv" ] || continue
    echo "$d"; return 0
  done
  return 1
}

# --- findings -----------------------------------------------------------
# Every check appends here. Severity is one of: info | minor | major | critical
# A 'critical' finding with imminent=1 is what triggers the alarm.
sc_finding() {   # sc_finding <severity> <area> <message> [imminent]
  local sev="$1" area="$2" msg="$3" imminent="${4:-0}"
  [ -z "$SC_RUN_DIR" ] && return 0
  printf '%s\t%s\t%s\t%s\n' "$sev" "$area" "$msg" "$imminent" >> "$SC_RUN_DIR/findings.tsv"
  return 0
}

# --- state / MOTD -------------------------------------------------------
# state.json is the single source of truth the MOTD renders from.
sc_state_write() {  # sc_state_write <phase> <severity> <message> [extra_json]
  local phase="$1" sev="$2" msg="$3" extra="${4:-}"
  local started="${SC_STARTED:-$(sc_now)}"
  local tmp="$SC_STATE.tmp.$$"
  {
    echo "{"
    printf '  "phase": "%s",\n'        "$phase"
    printf '  "severity": "%s",\n'     "$sev"
    printf '  "message": %s,\n'        "$(sc_json_str "$msg")"
    printf '  "started": "%s",\n'      "$started"
    printf '  "started_clock": "%s",\n' "${SC_STARTED_CLOCK:-$(sc_clock)}"
    printf '  "updated": "%s",\n'      "$(sc_now)"
    printf '  "updated_clock": "%s",\n' "$(sc_clock)"
    printf '  "date": "%s",\n'         "$(sc_datestamp)"
    printf '  "run_dir": "%s",\n'      "${SC_RUN_DIR:-}"
    printf '  "host": "%s"'            "$(hostname -s)"
    [ -n "$extra" ] && printf ',\n%s' "$extra"
    echo
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$SC_STATE"
  chmod 644 "$SC_STATE"
  # Re-render the login banner immediately so a mid-run SSH shows live status.
  "$SC_PREFIX/bin/motd-render.sh" > "$SC_MOTD.tmp.$$" 2>/dev/null \
    && mv -f "$SC_MOTD.tmp.$$" "$SC_MOTD" && chmod 644 "$SC_MOTD"
  rm -f "$SC_MOTD.tmp.$$"
  return 0
}

sc_json_str() {  # minimal JSON string escaper
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

sc_json_get() {  # sc_json_get <file> <key>  -- jq if present, sed fallback
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null
  else
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -1
  fi
}

# Highest severity wins when merging.
sc_sev_rank() {
  case "$1" in
    critical) echo 4 ;; major) echo 3 ;; minor) echo 2 ;; info) echo 1 ;; *) echo 0 ;;
  esac
}
sc_sev_max() {
  local a b; a=$(sc_sev_rank "$1"); b=$(sc_sev_rank "$2")
  [ "$a" -ge "$b" ] && echo "$1" || echo "$2"
}
