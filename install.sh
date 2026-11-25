#!/usr/bin/env bash
# Install or upgrade syscheck. Run as root from the unpacked release:
#
#   sudo ./install.sh                     fresh install (or reinstall)
#   sudo ./install.sh --user alice        run the analysis as this account
#   sudo ./install.sh --upgrade           used by `syscheck upgrade`
#   sudo ./install.sh --detect-sensors    also run lm-sensors' sensors-detect
#   sudo ./install.sh --no-packages       do not apt-get install anything
#
# Program files go to /opt/syscheck (root-owned, replaced on every upgrade).
# This machine's settings live in /etc/syscheck and its run history in
# /var/lib/syscheck; neither is ever overwritten by an install or upgrade,
# and neither is part of a release, so nothing moves between machines.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/syscheck
ETC=/etc/syscheck
VAR=/var/lib/syscheck
VERSION="$(cat "$SRC/VERSION")"
USER_ARG=""; UPGRADE=0; SENSORS=0; PACKAGES=1

while [ $# -gt 0 ]; do
  case "$1" in
    --user)           USER_ARG="${2:-}"; shift ;;
    --upgrade)        UPGRADE=1 ;;
    --detect-sensors) SENSORS=1 ;;
    --no-packages)    PACKAGES=0 ;;
    -h|--help)        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" = "0" ] || { echo "run this as root: sudo $0" >&2; exit 1; }

if [ -t 1 ]; then C=$'\033[1;36m'; G=$'\033[32m'; Y=$'\033[33m'; X=$'\033[0m'; else C=""; G=""; Y=""; X=""; fi
say() { printf '%s==>%s %s\n' "$C" "$X" "$*"; }

OLD_VERSION="$(cat "$PREFIX/VERSION" 2>/dev/null || { [ -d "$PREFIX" ] && echo "pre-0.2"; } || echo "")"
if [ -n "$OLD_VERSION" ]; then say "syscheck $OLD_VERSION -> $VERSION"; else say "installing syscheck $VERSION"; fi

# ---------------------------------------------------------------- packages
# Everything else it uses (flock, setpriv, findmnt, lsblk, journalctl) ships
# with every systemd distribution.
if [ "$PACKAGES" = "1" ]; then
  MISSING=()
  command -v smartctl >/dev/null || MISSING+=(smartmontools)
  command -v sensors  >/dev/null || MISSING+=(lm-sensors)
  command -v iostat   >/dev/null || MISSING+=(sysstat)
  command -v jq       >/dev/null || MISSING+=(jq)
  command -v bc       >/dev/null || MISSING+=(bc)
  command -v curl     >/dev/null || MISSING+=(curl)
  if [ ${#MISSING[@]} -gt 0 ]; then
    if command -v apt-get >/dev/null; then
      say "installing packages: ${MISSING[*]}"
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
    elif command -v pacman >/dev/null; then
      # No -y: syncing the databases without a full upgrade is a partial
      # upgrade, which Arch does not support. Install from the current sync.
      PAC=("${MISSING[@]/lm-sensors/lm_sensors}")
      say "installing packages: ${PAC[*]}"
      pacman -S --needed --noconfirm "${PAC[@]}" || \
        echo "${Y}pacman could not install them; run 'sudo pacman -Syu ${PAC[*]}' and install again${X}"
    else
      echo "${Y}unknown package manager: install these yourself: ${MISSING[*]}${X}"
    fi
  fi
fi

# sensors-detect probes the SMBus and I2C buses. That is harmless on most
# machines but has hung or confused some laptop chipsets, so it only runs when
# asked for. The CPU temperature works without it.
if [ "$SENSORS" = "1" ] && command -v sensors-detect >/dev/null; then
  say "detecting hardware sensors"
  yes '' | sensors-detect --auto >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- settings
mkdir -p "$ETC"; chmod 0755 "$ETC"

# Before 0.2 the settings lived inside the program directory. Carry over any
# value that differs from the new defaults, then leave the old file to be
# replaced with the program.
LEGACY="$PREFIX/etc/syscheck.conf"
if [ ! -f "$ETC/syscheck.conf" ] && [ -f "$LEGACY" ] && [ ! -f "$PREFIX/VERSION" ]; then
  say "moving settings from $LEGACY to $ETC/syscheck.conf"
  {
    echo "# Settings for this machine only. Written by \`syscheck settings\`."
    echo "# Defaults: $PREFIX/etc/syscheck.conf"
    for v in SC_USER SC_MODEL SC_EFFORT SC_CLAUDE_TIMEOUT SC_MAX_BUDGET_USD SC_ALARM_SECONDS \
             SC_KEEP_RUNS SC_MAX_LOOKBACK_DAYS SC_DISK SC_LOG_MAX_LINES SC_LOG_HEAD SC_LOG_TAIL SC_FULL_MAX_LINES; do
      old="$(unset "$v"; . "$LEGACY" 2>/dev/null; printf '%s' "${!v:-}")"
      new="$(unset "$v"; . "$SRC/etc/syscheck.conf" 2>/dev/null; printf '%s' "${!v:-}")"
      [ -n "$old" ] && [ "$old" != "$new" ] || continue
      # A disk setting that only names the root disk is better left automatic.
      if [ "$v" = "SC_DISK" ]; then
        rootdisk="/dev/$(lsblk -nrso NAME,TYPE "$(findmnt -nvo SOURCE /)" 2>/dev/null | awk '$2=="disk"{print $1; exit}')"
        [ "$old" = "$rootdisk" ] && continue
      fi
      printf '%s=%q\n' "$v" "$old"
    done
  } > "$ETC/syscheck.conf"
  chmod 0644 "$ETC/syscheck.conf"
fi

# The analysis account: --user, else what is already configured, else the
# account that ran sudo, else the first ordinary login account.
current_user="$( [ -f "$ETC/syscheck.conf" ] && (unset SC_USER; . "$ETC/syscheck.conf" 2>/dev/null; printf '%s' "${SC_USER:-}") || true)"
USER_NAME="${USER_ARG:-${current_user:-}}"
if [ -z "$USER_NAME" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then USER_NAME="$SUDO_USER"; fi
[ -n "$USER_NAME" ] || USER_NAME="$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /(nologin|false)$/ {print $1; exit}')"
[ -n "$USER_NAME" ] && id "$USER_NAME" >/dev/null 2>&1 || { echo "no usable account found; pass --user NAME" >&2; exit 1; }
[ "$(id -u "$USER_NAME")" != "0" ] || { echo "the analysis must not run as root; pass --user NAME" >&2; exit 1; }

# ----------------------------------------------------------------- program
# Stage the new tree next to the old one and swap, so a failed copy never
# leaves a half-installed program behind.
say "installing the program to $PREFIX"
NEW="$PREFIX.new"
rm -rf "$NEW"
mkdir -p "$NEW"/{bin,lib,modules,prompt,share,etc}
install -m 0755 "$SRC"/bin/*                "$NEW/bin/"
install -m 0644 "$SRC"/lib/*.sh             "$NEW/lib/"
install -m 0644 "$SRC"/modules/*.sh         "$NEW/modules/"
install -m 0644 "$SRC"/prompt/*.md          "$NEW/prompt/"
install -m 0644 "$SRC"/share/*              "$NEW/share/"
install -m 0644 "$SRC"/etc/syscheck.conf "$SRC"/etc/syscheck.sudoers "$SRC"/etc/syscheck.logrotate "$NEW/etc/"
install -m 0755 "$SRC"/etc/99-syscheck      "$NEW/etc/"
install -m 0644 "$SRC"/etc/syscheck-banner.sh "$NEW/etc/"
install -m 0644 "$SRC"/VERSION              "$NEW/VERSION"
chown -R root:root "$NEW"
find "$NEW" -type d -exec chmod 0755 {} +
if [ -d "$PREFIX" ]; then
  rm -rf "$PREFIX.old"; mv "$PREFIX" "$PREFIX.old"; mv "$NEW" "$PREFIX"; rm -rf "$PREFIX.old"
else
  mv "$NEW" "$PREFIX"
fi

# From here on, use the installed copy's helpers.
set +eu
SC_PREFIX="$PREFIX"
. "$PREFIX/lib/common.sh"
. "$PREFIX/lib/settings.sh"
[ "$(sc_host_raw SC_USER)" = "$USER_NAME" ] || sc_conf_write SC_USER "$USER_NAME"
. "$PREFIX/lib/common.sh"
set -eu

# What Claude is told about this machine. Generated once, here, from this
# machine's own hardware; the owner is expected to edit it.
if [ ! -f "$ETC/machine.md" ]; then
  say "describing this machine for Claude ($ETC/machine.md)"
  "$PREFIX/bin/describe.sh" > "$ETC/machine.md" 2>/dev/null || true
  chmod 0644 "$ETC/machine.md"
fi

# ------------------------------------------------------------- integration
say "applying settings: schedule, sudoers grant, login banner"
"$PREFIX/bin/apply.sh" || echo "${Y}some settings could not be applied; see above${X}"

# Seed a banner so the first login before the first run is not blank.
if [ ! -f "$SC_STATE" ]; then
  now="$(date '+%Y-%m-%d %H:%M:%S')"; clk="$(date '+%I:%M %p' | sed 's/^0//')"
  cat > "$SC_STATE" <<J
{
  "phase": "pending",
  "severity": "none",
  "message": "Installed. The first check runs at $SC_SCHEDULE, or run 'syscheck run' now.",
  "started": "$now", "started_clock": "$clk", "updated": "$now", "updated_clock": "$clk",
  "date": "$(date '+%d %b')", "run_dir": "", "host": "$(hostname -s)"
}
J
  chmod 0644 "$SC_STATE"
  "$PREFIX/bin/motd-render.sh" > "$SC_MOTD" 2>/dev/null || true
  chmod 0644 "$SC_MOTD"
fi

# ------------------------------------------------------------------ verify
say "checking"
fail=0; warn=0
ok()   { printf '    %sok%s   %s\n' "$G" "$X" "$1"; }
bad()  { printf '    %sFAIL%s %s\n' "$Y" "$X" "$1"; fail=1; }
note() { printf '    %s--%s   %s\n' "$Y" "$X" "$1"; warn=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

check "smartctl can read $SC_DISK"             "smartctl -i '$SC_DISK'"
check "$USER_NAME can use the diagnostics wrapper" "runuser -u '$USER_NAME' -- sudo -n $PREFIX/bin/priv-read.sh smart-health"
if [ "$SC_ENABLED" = "on" ]; then check "daily run scheduled at $SC_SCHEDULE" "systemctl is-enabled --quiet syscheck.timer"; fi
check "syscheck command on PATH"               "test -x /usr/local/bin/syscheck"
CLAUDE_OK=0
if runuser -u "$USER_NAME" -- env HOME="$SC_HOME" PATH="$SC_USER_PATH" claude --version >/dev/null 2>&1; then
  if [ "$(runuser -u "$USER_NAME" -- env HOME="$SC_HOME" PATH="$SC_USER_PATH" claude auth status --json 2>/dev/null | jq -r '.loggedIn // false')" = "true" ]; then
    ok "Claude Code is installed and logged in for $USER_NAME"; CLAUDE_OK=1
  else
    note "Claude Code is installed for $USER_NAME but not logged in"
  fi
else
  note "Claude Code is not installed for $USER_NAME (runs will use the rules only until it is)"
fi
if command -v ffplay >/dev/null || command -v pw-play >/dev/null; then ok "an audio player exists for the alarm"
else note "no ffplay or pw-play: the alarm cannot sound (install ffmpeg, or: syscheck set alarm off)"; fi

echo
if [ "$fail" = "0" ]; then say "syscheck $VERSION is installed."; else say "installed, but some checks failed (see above)."; fi
if [ "$UPGRADE" = "0" ]; then
  echo
  echo "  Next steps:"
  [ "$CLAUDE_OK" = "1" ] || echo "    syscheck claude install     install Claude Code for $USER_NAME (if missing)"
  [ "$CLAUDE_OK" = "1" ] || echo "    syscheck claude login       log in to Claude (works over SSH)"
  echo "    sudo syscheck describe --edit   tell Claude what this machine is for"
  echo "    syscheck run                run the first check now (a few minutes)"
  echo "    syscheck settings           schedule, model, budget, alarm, banner, note"
  echo
fi
exit "$fail"
