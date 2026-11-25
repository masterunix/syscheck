#!/usr/bin/env bash
# Identity, firmware, CPU, and the thermal picture.
# On a 2012 SFF box the two things that actually kill it are heat and the disk.
mod_hardware() {
  local L="$SC_RUN_DIR/10-hardware.log"

  sc_sh "$L" "identity" 'hostnamectl; echo; uptime; echo; who -b'
  sc_run "$L" "kernel" -- uname -a
  sc_sh "$L" "os-release" 'cat /etc/os-release'

  if [ "$(id -u)" = "0" ] && command -v dmidecode >/dev/null; then
    sc_sh "$L" "system/board/bios" \
      'dmidecode -t system -t baseboard -t bios 2>/dev/null | grep -vE "Handle 0x|^$|UUID"'
    sc_sh "$L" "memory-modules" \
      'dmidecode -t memory 2>/dev/null | grep -E "Size:|Speed:|Manufacturer:|Part Number:|Locator:|Type:|Rank" | grep -v "No Module"'
    sc_sh "$L" "chassis" 'dmidecode -t chassis 2>/dev/null | grep -E "Type:|State:|Boot-up|Power Supply|Thermal"'

    # BIOS date tells us how far behind firmware is; on Ivy Bridge that matters
    # for microcode mitigations more than for stability.
    local bios_date
    bios_date=$(dmidecode -s bios-release-date 2>/dev/null)
    [ -n "$bios_date" ] && sc_metric "bios_date" "$bios_date"
  fi

  sc_sh "$L" "cpu" 'lscpu'
  sc_sh "$L" "cpu-vulnerabilities" \
    'for f in /sys/devices/system/cpu/vulnerabilities/*; do printf "%-24s %s\n" "$(basename $f)" "$(cat $f)"; done'
  sc_sh "$L" "cpu-frequency" \
    'grep "MHz" /proc/cpuinfo | sort -u | head; echo; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null'
  sc_sh "$L" "microcode" 'grep -m1 microcode /proc/cpuinfo'

  # Thermal throttling counters. Non-zero and climbing means the heatsink is
  # clogged with 13 years of dust, which is the single most common failure
  # mode for a box of this vintage.
  local throttle=0 t
  for t in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
    [ -r "$t" ] || continue
    throttle=$(( throttle + $(cat "$t" 2>/dev/null || echo 0) ))
  done
  sc_metric "cpu_throttle_events" "$throttle"
  echo "### thermal throttle events (all cores): $throttle" >> "$L"

  # --- temperatures -----------------------------------------------------
  local T="$SC_RUN_DIR/11-thermal.log"
  local pkg_temp="" zone
  for zone in /sys/class/thermal/thermal_zone*; do
    [ -r "$zone/temp" ] || continue
    local type raw c
    type=$(cat "$zone/type" 2>/dev/null)
    raw=$(cat "$zone/temp" 2>/dev/null || echo 0)
    c=$(( raw / 1000 ))
    printf '%-18s %s  %s C\n' "$(basename "$zone")" "$type" "$c" >> "$T"
    [ "$type" = "x86_pkg_temp" ] && pkg_temp="$c"
    # trip points tell us where the firmware will start throttling
    local tp
    for tp in "$zone"/trip_point_*_temp; do
      [ -r "$tp" ] || continue
      printf '    trip %-6s %s C (%s)\n' \
        "$(basename "$tp" | sed 's/trip_point_//;s/_temp//')" \
        "$(( $(cat "$tp") / 1000 ))" \
        "$(cat "${tp%_temp}_type" 2>/dev/null)" >> "$T"
    done
  done

  # coretemp per-core via hwmon, plus the HP EC sensors (fan speed lives here)
  local h
  for h in /sys/class/hwmon/hwmon*; do
    local name; name=$(cat "$h/name" 2>/dev/null) || continue
    echo "--- hwmon $(basename "$h") ($name)" >> "$T"
    local f
    for f in "$h"/temp*_input "$h"/fan*_input "$h"/in*_input; do
      [ -r "$f" ] || continue
      local base label val unit
      base="${f%_input}"
      label=$(cat "${base}_label" 2>/dev/null || basename "$base")
      val=$(cat "$f" 2>/dev/null || echo "")
      [ -z "$val" ] && continue
      case "$(basename "$f")" in
        temp*) val=$(( val / 1000 )); unit="C" ;;
        fan*)  unit="RPM" ;;
        *)     unit="mV" ;;
      esac
      printf '    %-22s %s %s\n' "$label" "$val" "$unit" >> "$T"
      case "$(basename "$f")" in
        fan*) sc_metric "fan_$(basename "$base")" "$val" ;;
      esac
      # highest core temp is the number that matters
      if [ "$name" = "coretemp" ] && [ "$unit" = "C" ]; then
        if [ -z "$pkg_temp" ] || [ "$val" -gt "$pkg_temp" ]; then pkg_temp="$val"; fi
      fi
    done
  done

  command -v sensors >/dev/null && sc_run "$T" "lm-sensors" -- sensors

  if [ -n "$pkg_temp" ]; then
    sc_metric "cpu_temp_c" "$pkg_temp"
    echo "### peak CPU temperature: ${pkg_temp} C" >> "$T"
    if   [ "$pkg_temp" -ge 95 ]; then
      sc_finding critical thermal "CPU at ${pkg_temp}C - at or past thermal shutdown threshold" 1
    elif [ "$pkg_temp" -ge 85 ]; then
      sc_finding major thermal "CPU at ${pkg_temp}C during the quiet scheduled run - heatsink or fan almost certainly obstructed"
    elif [ "$pkg_temp" -ge 75 ]; then
      sc_finding minor thermal "CPU at ${pkg_temp}C during the quietest hour of the day - worth a dust check"
    fi
  fi
  [ "$throttle" -gt 0 ] && sc_finding minor thermal "$throttle thermal throttle events recorded since boot"

  # --- ECC / machine check ---------------------------------------------
  local M="$SC_RUN_DIR/12-mce.log"
  sc_sh "$M" "EDAC memory controllers" \
    'if [ -d /sys/devices/system/edac/mc ]; then for m in /sys/devices/system/edac/mc/mc*; do echo "$m: CE=$(cat $m/ce_count 2>/dev/null) UE=$(cat $m/ue_count 2>/dev/null)"; done; else echo "no EDAC (this board/CPU has no ECC reporting)"; fi'
  sc_sh "$M" "machine check banks" \
    'ls /sys/devices/system/machinecheck/ 2>/dev/null || echo none'
  sc_sh "$M" "MCE in kernel log" \
    'journalctl -k -b --no-pager 2>/dev/null | grep -iE "mce|machine check|hardware error" | tail -30 || echo none'

  local ce=0 ue=0 m
  for m in /sys/devices/system/edac/mc/mc*; do
    [ -r "$m/ce_count" ] || continue
    ce=$(( ce + $(cat "$m/ce_count" 2>/dev/null || echo 0) ))
    ue=$(( ue + $(cat "$m/ue_count" 2>/dev/null || echo 0) ))
  done
  sc_metric "edac_ce" "$ce"; sc_metric "edac_ue" "$ue"
  [ "$ue" -gt 0 ] && sc_finding critical memory "$ue uncorrectable ECC memory errors - RAM is failing" 1
  [ "$ce" -gt 0 ] && sc_finding major memory "$ce correctable ECC errors logged"

  return 0
}
