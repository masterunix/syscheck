#!/usr/bin/env bash
# Memory pressure, swap behaviour, OOM history.
mod_memory() {
  local L="$SC_RUN_DIR/30-memory.log"

  sc_sh "$L" "free" 'free -h; echo; free -m | tail -n +2'
  sc_sh "$L" "meminfo" 'cat /proc/meminfo'
  sc_sh "$L" "vmstat" 'vmstat 2 3'
  sc_sh "$L" "swappiness / overcommit" \
    'for f in vm.swappiness vm.overcommit_memory vm.vfs_cache_pressure vm.min_free_kbytes; do printf "%-24s %s\n" "$f" "$(sysctl -n $f 2>/dev/null)"; done'
  sc_sh "$L" "top 15 by RSS" \
    'ps -eo pid,ppid,rss,pmem,pcpu,etimes,comm --sort=-rss | head -16'
  sc_sh "$L" "per-cgroup memory (top services)" \
    'systemd-cgtop -m -n1 -b --order=memory 2>/dev/null | head -20 || echo unavailable'

  local total avail used_pct swap_total swap_used swap_pct
  total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  swap_total=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
  swap_used=$(( swap_total - $(awk '/SwapFree/{print $2}' /proc/meminfo) ))
  used_pct=$(( (total - avail) * 100 / total ))
  swap_pct=0; [ "$swap_total" -gt 0 ] && swap_pct=$(( swap_used * 100 / swap_total ))

  sc_metric "mem_used_pct" "$used_pct"
  sc_metric "mem_avail_kb" "$avail"
  sc_metric "swap_used_pct" "$swap_pct"
  sc_metric "swap_used_kb" "$swap_used"

  [ "$used_pct" -ge 95 ] && sc_finding major memory "Memory ${used_pct}% used with only $(( avail / 1024 ))MB available"
  [ "$swap_pct" -ge 60 ] && sc_finding major memory "Swap ${swap_pct}% used - the box is paging hard, and on a spinning disk that is brutal"
  [ "$swap_pct" -ge 25 ] && [ "$swap_pct" -lt 60 ] && sc_finding minor memory "Swap ${swap_pct}% used"

  # OOM kills. systemd-oomd is running on this box so check both sources.
  local O="$SC_RUN_DIR/31-oom.log"
  sc_sh "$O" "kernel OOM kills (this boot)" \
    'journalctl -k -b --no-pager 2>/dev/null | grep -iE "out of memory|oom-kill|killed process" | tail -40 || echo none'
  sc_sh "$O" "systemd-oomd actions" \
    'journalctl -u systemd-oomd --since "48 hours ago" --no-pager 2>/dev/null | grep -iE "killed|swap|pressure" | tail -30 || echo none'

  local oom_count
  oom_count=$(sc_num "$(journalctl -k -b --no-pager 2>/dev/null | grep -icE "oom-kill|killed process")")
  sc_metric "oom_kills" "$oom_count"
  [ "${oom_count:-0}" -gt 0 ] && sc_finding major memory "$oom_count OOM kill events since boot - something is over-committing RAM"

  # Memory pressure stall information: the most honest signal that the box is
  # thrashing, and it exists on this kernel.
  sc_sh "$L" "PSI pressure" \
    'for p in cpu memory io; do printf "%-8s %s\n" "$p" "$(head -1 /proc/pressure/$p 2>/dev/null)"; done'
  local io_psi
  io_psi=$(awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg300=/){split($i,a,"="); print a[2]}}' /proc/pressure/io 2>/dev/null)
  [ -n "$io_psi" ] && sc_metric "psi_io_avg300" "$io_psi"
  if [ -n "$io_psi" ] && [ "$(echo "$io_psi > 25" | bc -l 2>/dev/null)" = "1" ]; then
    sc_finding major storage "I/O pressure stall at ${io_psi}% over 5 minutes - tasks are spending real time blocked on the disk"
  fi

  return 0
}
