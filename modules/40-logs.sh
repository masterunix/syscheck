#!/usr/bin/env bash
# Kernel and system logs. Everything since the previous run, so nothing is
# seen twice and nothing is missed.
mod_logs() {
  local L="$SC_RUN_DIR/40-kernel.log"
  local J="$SC_RUN_DIR/41-journal.log"
  local since="${SC_SINCE:-24 hours ago}"

  echo "### window: since '$since'" >> "$J"

  sc_sh "$J" "priority<=err since last run" \
    "journalctl -p 3 --since '$since' --no-pager 2>/dev/null || echo none"
  sc_sh "$J" "priority=warning since last run (deduplicated)" \
    "journalctl -p 4..4 --since '$since' --no-pager -o cat 2>/dev/null | sed 's/[0-9]\\{3,\\}/N/g' | sort | uniq -c | sort -rn | head -40 || echo none"
  sc_sh "$J" "journal disk usage" 'journalctl --disk-usage'
  sc_sh "$J" "boot history" 'journalctl --list-boots --no-pager 2>/dev/null | tail -15'

  # Hardware-level kernel messages. These are the ones that precede a failure.
  sc_sh "$L" "ATA / SATA link errors" \
    "journalctl -k --since '$since' --no-pager 2>/dev/null | grep -iE 'ata[0-9]+|link is slow|SError|failed command|hard resetting|softreset|exception Emask' || echo none"
  sc_sh "$L" "I/O and filesystem errors" \
    "journalctl -k --since '$since' --no-pager 2>/dev/null | grep -iE 'I/O error|EXT4-fs error|EXT4-fs warning|buffer I/O|critical medium|sector|remounting.*read-only|journal aborted' || echo none"
  sc_sh "$L" "kernel oops / BUG / call traces" \
    "journalctl -k --since '$since' --no-pager 2>/dev/null | grep -iE 'BUG:|kernel panic|Oops|call trace|general protection|soft lockup|hung task|watchdog' || echo none"
  sc_sh "$L" "USB / PCI / firmware complaints" \
    "journalctl -k --since '$since' --no-pager 2>/dev/null | grep -iE 'usb .*(disconnect|error|reset)|pcieport|AER:|firmware|ACPI Error|ACPI Warning' || echo none"
  sc_sh "$L" "segfaults and traps" \
    "journalctl --since '$since' --no-pager 2>/dev/null | grep -iE 'segfault|traps:|core dumped' || echo none"
  sc_sh "$L" "full dmesg tail" 'dmesg -T --level=err,warn 2>/dev/null || journalctl -k -b --no-pager | tail -60'

  # Counters drive the deterministic verdict; the text above is for reading.
  local ata_err io_err oops segv
  ata_err=$(sc_num "$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -icE 'failed command|hard resetting link|SError|exception Emask')")
  io_err=$(sc_num "$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -icE 'I/O error|EXT4-fs error|critical medium error|buffer I/O error')")
  oops=$(sc_num "$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -icE 'BUG:|kernel panic|Oops|general protection|soft lockup')")
  segv=$(sc_num "$(journalctl --since "$since" --no-pager 2>/dev/null | grep -icE 'segfault|core dumped')")

  sc_metric "ata_errors" "$ata_err"
  sc_metric "io_errors"  "$io_err"
  sc_metric "kernel_oops" "$oops"
  sc_metric "segfaults"  "$segv"

  # ATA resets on the only disk in the machine are a pre-failure signature.
  if [ "${ata_err:-0}" -ge 20 ]; then
    sc_finding critical kernel "$ata_err SATA link errors / command failures in the last day - the link to the only disk in this box is failing" 1
  elif [ "${ata_err:-0}" -gt 0 ]; then
    sc_finding major kernel "$ata_err SATA link errors in the last day - check the cable, then the drive"
  fi
  if [ "${io_err:-0}" -ge 10 ]; then
    sc_finding critical kernel "$io_err block I/O / ext4 errors in the last day - data is not making it to or from the platters" 1
  elif [ "${io_err:-0}" -gt 0 ]; then
    sc_finding major kernel "$io_err block I/O or ext4 errors in the last day"
  fi
  [ "${oops:-0}" -gt 0 ] && sc_finding major kernel "$oops kernel oops/BUG/lockup events in the last day"
  [ "${segv:-0}" -ge 10 ] && sc_finding minor kernel "$segv segfaults in the last day"

  # Unexpected reboots: an aging PSU or CMOS battery shows up here first.
  local U="$SC_RUN_DIR/42-boots.log"
  sc_sh "$U" "last reboots" 'last -x --time-format iso reboot shutdown 2>/dev/null | head -15'
  sc_sh "$U" "boot list" 'journalctl --list-boots --no-pager 2>/dev/null | tail -10'

  # Count boots that ended without a clean shutdown, in bash rather than by
  # grepping the log -- sc_sh echoes each command above its output, so any
  # marker string would match its own command line.
  # Ask PID 1 directly whether it reached shutdown.target. Scanning the tail of
  # a boot is unreliable: any service stuck in a restart loop floods the journal
  # and pushes the real shutdown sequence out of the window. Server-side
  # --grep over the whole boot has no such blind spot.
  local dirty_boots=0 checked=0 b hits sleeps last_sleep
  echo "### boots that ended without a recorded clean shutdown:" >> "$U"
  # Previous boots only (negative offsets); newer journalctl prints a header.
  for b in $(journalctl --list-boots --no-pager 2>/dev/null | awk '$1 ~ /^-[0-9]+$/ {print $1}' | tail -8); do
    checked=$(( checked + 1 ))
    # Shutdown markers from PID 1 and logind. The journald messages ("Journal
    # stopped") are not used: journald restarts mid-boot during upgrades.
    hits=$(journalctl -b "$b" _PID=1 + SYSLOG_IDENTIFIER=systemd-logind --no-pager \
             --grep='Reached target (shutdown\.target|System Shutdown|System Power Off|System Reboot)|Shutting down\.|System is (powering down|rebooting|halting)|shutdown-ramfs' 2>/dev/null \
           | grep -cE '^[A-Z][a-z]{2} ')     # real log lines only, not "-- No entries --"
    hits=$(sc_num "$hits")
    # A laptop that hibernates (or suspends until the battery runs out) ends
    # its boot without a shutdown, but nothing crashed. The kernel logs the
    # entry into the sleep state as the boot's last act.
    sleeps=$(journalctl -b "$b" -k --no-pager \
               --grep='PM: hibernation: hibernation entry|PM: suspend entry' 2>/dev/null \
             | grep -cE '^[A-Z][a-z]{2} ')
    sleeps=$(sc_num "$sleeps")
    last_sleep=$(journalctl -b "$b" -k --no-pager -o cat \
               --grep='PM: hibernation: hibernation entry|PM: suspend entry|PM: suspend exit|PM: hibernation: hibernation exit' 2>/dev/null | tail -1)
    if [ "$hits" -gt 0 ]; then
      echo "  boot $b: clean ($hits shutdown markers)" >> "$U"
    elif [ "$sleeps" -gt 0 ] && echo "$last_sleep" | grep -q 'hibernation entry'; then
      echo "  boot $b: ended in hibernation (not a crash)" >> "$U"
    elif [ "$sleeps" -gt 0 ] && echo "$last_sleep" | grep -q 'suspend entry'; then
      echo "  boot $b: ended while suspended - the battery or power likely ran out (not a crash)" >> "$U"
    else
      echo "  boot $b: NO clean shutdown - hard power-off, power loss, or lockup" >> "$U"
      dirty_boots=$(( dirty_boots + 1 ))
    fi
  done
  [ "$checked" = "0" ] && echo "  (only the current boot is in the journal)" >> "$U"
  sc_metric "unclean_boots_recent" "$dirty_boots"
  sc_metric "boots_checked" "$checked"

  # An aging PSU, overheating, or a hard lockup all show up here first.
  if [ "$checked" -ge 4 ] && [ "$dirty_boots" -ge 3 ]; then
    sc_finding major power "$dirty_boots of the last $checked boots ended without a clean shutdown - suspect the PSU, overheating, or a hard lockup"
  elif [ "$dirty_boots" -ge 2 ]; then
    sc_finding minor power "$dirty_boots of the last $checked boots ended without a clean shutdown"
  fi

  return 0
}
