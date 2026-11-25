#!/usr/bin/env bash
# Remove syscheck.
#
#   uninstall.sh            remove the program, cron entry, sudoers grant and
#                           banner hook; keep settings and run history
#   uninstall.sh --purge    also delete /etc/syscheck, /var/lib/syscheck and
#                           the log
#
# Claude Code and its login in the analysis account's home are left alone.
set -uo pipefail
SC_PREFIX=/opt/syscheck
[ "$(id -u)" = "0" ] || { echo "run as root: sudo syscheck uninstall" >&2; exit 1; }
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

if [ -t 0 ]; then
  if [ "$PURGE" = "1" ]; then q="Remove syscheck AND delete its settings and all run history?"
  else q="Remove syscheck (settings and run history are kept)?"; fi
  read -r -p "$q [y/N] " a; case "$a" in y|Y|yes) : ;; *) echo "cancelled"; exit 0 ;; esac
fi

"$SC_PREFIX/bin/alarm.sh" stop >/dev/null 2>&1 || true
rm -f /etc/cron.d/syscheck /etc/sudoers.d/99-syscheck /etc/update-motd.d/99-syscheck \
      /etc/logrotate.d/syscheck /usr/local/bin/syscheck
rm -rf "$SC_PREFIX"
echo "removed the program, schedule, sudoers grant and login banner"

if [ "$PURGE" = "1" ]; then
  rm -rf /etc/syscheck /var/lib/syscheck
  rm -f /var/log/syscheck.log*
  echo "deleted settings, run history and logs"
else
  echo "kept /etc/syscheck (settings) and /var/lib/syscheck (history). Remove them with: sudo rm -rf /etc/syscheck /var/lib/syscheck"
fi
