#!/usr/bin/env bash
# Verify the alarm can actually make noise -- SILENTLY. An alarm path that has
# quietly broken is worse than no alarm at all, because you would trust it.
# This checks the device and the daemon without playing anything.
mod_audio() {
  [ "${SC_ALARM:-on}" = "off" ] && return 0
  local L="$SC_RUN_DIR/95-audio.log"
  local ok=1

  sc_sh "$L" "playback devices" 'aplay -l 2>&1'
  sc_sh "$L" "pipewire process" 'pgrep -a pipewire 2>/dev/null || echo "pipewire NOT running"'
  sc_sh "$L" "pipewire socket for uid ${SC_UID}" \
    "ls -la /run/user/${SC_UID}/pipewire-0 2>&1 || echo 'no pipewire socket'"
  sc_sh "$L" "alarm assets" \
    "ls -la '$SC_PREFIX/share/alarm.mp3' '$SC_PREFIX/share/speaker-test.wav' 2>&1"
  sc_sh "$L" "players" \
    'for p in pw-play ffplay aplay; do printf "%-10s %s\n" "$p" "$(command -v $p || echo MISSING)"; done'

  aplay -l 2>/dev/null | grep -q '^card' || ok=0
  [ -S "/run/user/${SC_UID}/pipewire-0" ] || pgrep -x pipewire >/dev/null 2>&1 || ok=0
  [ -f "$SC_PREFIX/share/alarm.mp3" ] || ok=0
  command -v ffplay >/dev/null || command -v pw-play >/dev/null || ok=0

  sc_metric "alarm_path_ok" "$ok"
  echo "### alarm path usable: $ok" >> "$L"
  [ "$ok" = "0" ] && sc_finding minor system \
    "The critical-alarm audio path is broken - a genuinely urgent fault would fail to sound. Run: /opt/syscheck/bin/alarm.sh test"

  return 0
}
