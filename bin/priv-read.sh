#!/usr/bin/env bash
# Root-owned allowlist of READ-ONLY privileged diagnostics.
#
# This is the only thing the desktop user is granted passwordless sudo for.
# Giving `sudo smartctl *` instead would hand over every --set flag the tool
# has; routing through a fixed subcommand list means the grant is exactly as
# wide as the diagnostics need and no wider. The file is root-owned 0755, so
# the user it serves cannot edit it.
#
# Usage: sudo /opt/syscheck/bin/priv-read.sh <subcommand> [args]
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Never let a pager start under sudo: a pager is a shell escape.
export PAGER=cat SYSTEMD_PAGER=cat SYSTEMD_LESSSECURE=1

# Fixed path, never from the environment: this runs as root.
SC_PREFIX=/opt/syscheck
. "$SC_PREFIX/lib/common.sh"
DISK="$SC_DISK"
sub="${1:-help}"; shift || true

# Only ever operate on a real block device, never on a path someone smuggled in.
valid_disk() {
  case "$1" in
    /dev/sd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/vd[a-z]) [ -b "$1" ] ;;
    *) return 1 ;;
  esac
}
[ $# -gt 0 ] && valid_disk "${1:-}" && { DISK="$1"; shift; }

case "$sub" in
  smart-info)      exec smartctl -i "$DISK" ;;
  smart-health)    exec smartctl -H "$DISK" ;;
  smart-attrs)     exec smartctl -A "$DISK" ;;
  smart-all)       exec smartctl -x "$DISK" ;;
  smart-errors)    exec smartctl -l error "$DISK" ;;
  smart-selftest)  exec smartctl -l selftest "$DISK" ;;
  smart-capabilities) exec smartctl -c "$DISK" ;;
  smart-test-short)   exec smartctl -t short "$DISK" ;;
  smart-test-status)  exec smartctl -c "$DISK" ;;

  dmidecode)
    case "${1:-}" in
      system|baseboard|bios|memory|chassis|processor|cache|connector|slot)
        exec dmidecode -t "$1" ;;
      "") exec dmidecode ;;
      *)  echo "dmidecode: type not allowed" >&2; exit 2 ;;
    esac ;;

  fsinfo)
    valid_disk "${1:-}" && exec tune2fs -l "$1"
    exec tune2fs -l "${DISK}2" ;;

  hdparm)          exec hdparm -C -W -I "$DISK" ;;
  dmesg)           exec dmesg -T ;;
  edac)            exec bash -c 'for m in /sys/devices/system/edac/mc/mc*; do echo "$m ce=$(cat $m/ce_count 2>/dev/null) ue=$(cat $m/ue_count 2>/dev/null)"; done' ;;
  lsof-deleted)    exec bash -c "lsof -nP 2>/dev/null | grep -i deleted | head -50" ;;
  fuser-disk)      exec bash -c "ls -l /proc/*/fd 2>/dev/null | wc -l" ;;

  journal)
    # journalctl is read-only except for the handful of flags that rotate,
    # vacuum or flush the journal. Reject those and pass the rest through.
    for a in "$@"; do
      case "$a" in
        --vacuum*|--rotate|--flush|--sync|--relinquish-var|--smart-relinquish-var|--setup-keys|--update-catalog)
          echo "journal: '$a' modifies the journal and is not permitted" >&2; exit 2 ;;
        # --cursor-file writes to any path it is given, as root. The others
        # point journalctl at arbitrary files, directories or disk images.
        --cursor-file*|--image*|--root*|--file*|--directory*|-D*|-i*|--namespace*|--machine*|-M*)
          echo "journal: '$a' is not permitted" >&2; exit 2 ;;
      esac
    done
    exec journalctl --no-pager "$@" ;;

  readlog)
    # Read a root-only logfile. Confined to /var/log with no traversal.
    f="${1:-}"
    case "$f" in
      /var/log/*) : ;;
      *) echo "readlog: only /var/log paths are permitted" >&2; exit 2 ;;
    esac
    case "$f" in *..*) echo "readlog: path traversal rejected" >&2; exit 2 ;; esac
    # Resolve symlinks first: a link inside /var/log could point anywhere.
    f="$(readlink -f -- "$f")"
    case "$f" in /var/log/*) : ;; *) echo "readlog: resolves outside /var/log" >&2; exit 2 ;; esac
    [ -f "$f" ] || { echo "readlog: not a regular file" >&2; exit 2; }
    exec tail -c 2000000 "$f" ;;

  pg-activity)
    exec su - postgres -c "psql -tAc \"select pid, state, now()-query_start as dur, left(query,120) from pg_stat_activity where state <> 'idle' order by query_start;\"" ;;
  pg-sizes)
    exec su - postgres -c "psql -tAc \"select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by pg_database_size(datname) desc;\"" ;;

  du)
    d="${1:-/}"
    case "$d" in /*) : ;; *) echo "du: absolute paths only" >&2; exit 2 ;; esac
    case "$d" in *..*) echo "du: path traversal rejected" >&2; exit 2 ;; esac
    exec timeout 120 du -xh --max-depth="${2:-2}" "$d" ;;

  help|*)
    cat <<'H'
Read-only privileged diagnostics. Subcommands:

  smart-info | smart-health | smart-attrs | smart-all | smart-errors
  smart-selftest | smart-capabilities | smart-test-short | smart-test-status
                                     [device]   default: the root disk
  dmidecode [system|baseboard|bios|memory|chassis|processor|cache|slot]
  fsinfo [device]                    tune2fs -l
  hdparm [device]                    power mode, write cache, identity
  dmesg                              dmesg -T
  edac                               ECC error counters
  lsof-deleted                       deleted-but-open files holding disk space
  journal <journalctl args>          read-only journalctl passthrough
  readlog /var/log/<file>            read a root-only logfile
  pg-activity | pg-sizes             postgres introspection
  du <abs-path> [depth]              disk usage as root
H
    exit 0 ;;
esac
