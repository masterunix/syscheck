#!/usr/bin/env bash
# Settings: the registry of user-facing names, their validation, and safe
# reads and writes of /etc/syscheck/syscheck.conf. Sourced by bin/syscheck.

SC_HOST_CONF="$SC_ETC/syscheck.conf"
SC_NOTE_FILE="$SC_ETC/note"

# name | variable | kind | description
# kinds: onoff, int:MIN:MAX, money, time, model, effort, user, disk, services, repo
SC_SETTINGS="
enabled|SC_ENABLED|onoff|run on a schedule every day
schedule|SC_SCHEDULE|time|time of the daily run, 24h HH:MM
analysis|SC_ANALYSIS|onoff|have Claude review each run
model|SC_MODEL|model|Claude model (sonnet, opus, haiku or a full model id)
effort|SC_EFFORT|effort|reasoning effort (low, medium, high, xhigh, max)
budget|SC_MAX_BUDGET_USD|money|spend cap per run in USD
timeout|SC_CLAUDE_TIMEOUT|int:60:14400|hard limit on the analysis, seconds
user|SC_USER|user|account that owns the Claude login and the audio session
disk|SC_DISK|disk|disk to check (auto = the root filesystem's disk)
services|SC_WATCH_SERVICES|services|services whose errors are read (default = built-in list)
alarm|SC_ALARM|onoff|sound an alarm when a fault looks imminent
alarm-seconds|SC_ALARM_SECONDS|int:10:3600|how long the alarm sounds, seconds
motd|SC_BANNER|onoff|show the result on the SSH login banner
keep-runs|SC_KEEP_RUNS|int:1:1000|how many runs to keep on disk
lookback-days|SC_MAX_LOOKBACK_DAYS|int:1:90|furthest back the journal scan reaches
repo|SC_REPO|repo|GitHub repository that upgrades come from
"

sc_setting_row() {  # sc_setting_row <name> -> "name|VAR|kind|desc"
  printf '%s\n' "$SC_SETTINGS" | awk -F'|' -v n="$1" '$1==n {print; exit}'
}

sc_setting_names() {
  printf '%s\n' "$SC_SETTINGS" | awk -F'|' 'NF>=4 {print $1}'
}

# Current effective value, as the scripts will see it.
sc_setting_value() {  # sc_setting_value <VAR>
  local v="${!1:-}"
  case "$1" in
    SC_USER)           [ -n "$(sc_host_raw SC_USER)" ] || v="auto ($SC_USER)" ;;
    SC_DISK)           [ -n "$(sc_host_raw SC_DISK)" ] || v="auto ($SC_DISK)" ;;
    SC_WATCH_SERVICES) [ -n "$v" ] || v="default" ;;
  esac
  printf '%s' "$v"
}

# The value written in the host file, if any (empty when only the default applies).
sc_host_raw() {
  [ -r "$SC_HOST_CONF" ] || return 0
  ( unset "$1"; . "$SC_HOST_CONF" 2>/dev/null; printf '%s' "${!1:-}" )
}

# Validate and normalise a value. Prints the value to store, or an error on stderr.
sc_setting_check() {  # sc_setting_check <kind> <value>
  local kind="$1" v="$2"
  case "$kind" in
    onoff)
      case "$v" in on|yes|true|1) echo on ;; off|no|false|0) echo off ;;
        *) echo "expected on or off" >&2; return 1 ;; esac ;;
    int:*)
      local lo hi; lo="$(echo "$kind" | cut -d: -f2)"; hi="$(echo "$kind" | cut -d: -f3)"
      [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ] \
        || { echo "expected a whole number from $lo to $hi" >&2; return 1; }
      echo "$v" ;;
    money)
      [[ "$v" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || { echo "expected an amount like 2.00" >&2; return 1; }
      echo "$v" ;;
    time)
      [[ "$v" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "expected HH:MM, for example 05:00" >&2; return 1; }
      printf '%02d:%s\n' "$((10#${v%%:*}))" "${v##*:}" ;;
    model)
      [[ "$v" =~ ^[A-Za-z0-9._-]+(\[[0-9a-z]+\])?$ ]] || { echo "not a model name" >&2; return 1; }
      echo "$v" ;;
    effort)
      case "$v" in low|medium|high|xhigh|max) echo "$v" ;;
        *) echo "expected low, medium, high, xhigh or max" >&2; return 1 ;; esac ;;
    user)
      [ "$v" = "auto" ] && { echo ""; return 0; }
      [[ "$v" =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$v" >/dev/null 2>&1 \
        || { echo "no such account: $v" >&2; return 1; }
      [ "$(id -u "$v")" != "0" ] || { echo "the analysis must not run as root" >&2; return 1; }
      echo "$v" ;;
    disk)
      [ "$v" = "auto" ] && { echo ""; return 0; }
      case "$v" in /dev/sd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/vd[a-z]|/dev/mmcblk[0-9]) : ;;
        *) echo "expected auto or a whole-disk device such as /dev/sda or /dev/nvme0n1" >&2; return 1 ;; esac
      [ -b "$v" ] || { echo "$v is not a block device on this machine" >&2; return 1; }
      echo "$v" ;;
    services)
      [ "$v" = "default" ] && { echo ""; return 0; }
      [[ "$v" =~ ^[A-Za-z0-9@._:\ -]+$ ]] || { echo "service names only, separated by spaces" >&2; return 1; }
      echo "$v" ;;
    repo)
      [[ "$v" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "expected owner/name" >&2; return 1; }
      echo "$v" ;;
    *) echo "unknown setting kind $kind" >&2; return 1 ;;
  esac
}

# Write one variable into the host config. Root only. The value is written with
# printf %q, so whatever it contains is data when root sources the file.
sc_conf_write() {  # sc_conf_write <VAR> <value>
  local var="$1" val="$2" tmp
  mkdir -p "$SC_ETC"
  [ -f "$SC_HOST_CONF" ] || printf '# Settings for this machine only. Written by `syscheck settings`.\n# Defaults: %s/etc/syscheck.conf\n' "$SC_PREFIX" > "$SC_HOST_CONF"
  tmp="$(mktemp "$SC_ETC/.conf.XXXXXX")"
  awk -v k="$var" 'index($0, k"=") != 1' "$SC_HOST_CONF" > "$tmp"
  printf '%s=%q\n' "$var" "$val" >> "$tmp"
  chmod 0644 "$tmp"; chown root:root "$tmp" 2>/dev/null
  mv -f "$tmp" "$SC_HOST_CONF"
  printf -v "$var" '%s' "$val"
}

# --- the personal note line on the banner ------------------------------------
sc_note_get() { [ -r "$SC_NOTE_FILE" ] && head -c 400 "$SC_NOTE_FILE" | head -1; }

sc_note_set() {  # sc_note_set <text>   (root)
  local t
  t="$(printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-300)"
  mkdir -p "$SC_ETC"
  if [ -z "$t" ]; then rm -f "$SC_NOTE_FILE"; return 0; fi
  printf '%s\n' "$t" > "$SC_NOTE_FILE.tmp" && chmod 0644 "$SC_NOTE_FILE.tmp" && mv -f "$SC_NOTE_FILE.tmp" "$SC_NOTE_FILE"
}
