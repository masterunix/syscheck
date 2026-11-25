#!/usr/bin/env bash
# Audible alarm for a fault severe enough that the box may not survive the day.
#
#   alarm.sh start [seconds]   loop the alarm (default 600s = 10 minutes)
#   alarm.sh stop              silence it
#   alarm.sh test              play a short burst to prove the path works
#   alarm.sh chime             single non-alarming chime
#   alarm.sh status            is it sounding right now?
#
# Audio lives in the desktop user's PipeWire session, so when root invokes this
# it drops to that user first -- root has no sound server of its own.
set -uo pipefail
SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

ACTION="${1:-start}"
DURATION="${2:-600}"
PIDFILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/syscheck-alarm.pid"
ALARM="$SC_PREFIX/share/alarm.mp3"
CHIME="$SC_PREFIX/share/speaker-test.wav"

# Re-exec as the desktop user if we are root.
if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid="$SC_UID" --regid="$SC_UID" --init-groups \
    env XDG_RUNTIME_DIR="/run/user/$SC_UID" HOME="$SC_HOME" \
    "$0" "$ACTION" "$DURATION"
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

alarm_stop() {
  if [ -f "$PIDFILE" ]; then
    local pgid; pgid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pgid" ] && kill -TERM -- "-$pgid" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  pkill -f "ffplay.*$(basename "$ALARM")" 2>/dev/null
  pkill -f "pw-play.*$(basename "$ALARM")" 2>/dev/null
  return 0
}

# Best-effort: an alarm nobody can hear because the mixer got turned down is
# not an alarm. Only nudge the volume for real alarms, never for the chime.
unmute() {
  command -v wpctl >/dev/null || return 0
  wpctl set-mute   @DEFAULT_AUDIO_SINK@ 0    2>/dev/null
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.9  2>/dev/null
  return 0
}

play_once() {
  local file="$1"
  if command -v ffplay >/dev/null; then
    ffplay -nodisp -autoexit -loglevel quiet "$file" </dev/null >/dev/null 2>&1
  elif command -v pw-play >/dev/null; then
    pw-play "$file" </dev/null >/dev/null 2>&1
  else
    return 1
  fi
}

case "$ACTION" in
  stop)   alarm_stop; echo "alarm stopped"; exit 0 ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
      then echo "sounding (pgid $(cat "$PIDFILE"))"; exit 0
      else echo "silent"; exit 1; fi ;;
  chime)  play_once "$CHIME"; exit $? ;;
  test)
    echo "playing 8s of the alarm..."
    timeout 9 ffplay -nodisp -autoexit -loglevel quiet -loop 2 "$ALARM" </dev/null >/dev/null 2>&1
    echo "if you heard nothing, the alarm path is broken"
    exit 0 ;;
esac

# --- start ---------------------------------------------------------------
[ -f "$ALARM" ] || { echo "alarm sound missing: $ALARM" >&2; exit 1; }
alarm_stop
unmute

# Detach into its own process group so the whole loop can be killed at once,
# and so it outlives the cron job that triggered it.
setsid bash -c '
  end=$(( $(date +%s) + '"$DURATION"' ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if command -v ffplay >/dev/null; then
      ffplay -nodisp -autoexit -loglevel quiet "'"$ALARM"'" </dev/null >/dev/null 2>&1
    else
      pw-play "'"$ALARM"'" </dev/null >/dev/null 2>&1
    fi
    sleep 0.2
  done
' </dev/null >/dev/null 2>&1 &

sleep 0.3
pgid=$(ps -o pgid= -p $! 2>/dev/null | tr -d ' ')
[ -n "$pgid" ] && echo "$pgid" > "$PIDFILE"

# Desktop notification too, in case someone is sitting at the machine.
command -v notify-send >/dev/null && \
  notify-send -u critical "SYSTEM CHECK: CRITICAL FAULT" \
    "This machine may not survive the day. See /var/lib/syscheck/latest/report.md" 2>/dev/null

# Also write it to every logged-in terminal.
command -v wall >/dev/null && \
  echo "SYSTEM CHECK: CRITICAL HARDWARE FAULT DETECTED - see /var/lib/syscheck/latest/report.md" | wall 2>/dev/null

echo "alarm sounding for ${DURATION}s (silence it with: $SC_PREFIX/bin/alarm.sh stop)"
