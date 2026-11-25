#!/usr/bin/env bash
# systemd health: what failed, what keeps restarting, what is quietly flapping.
mod_services() {
  SC_PG_UNIT="$(systemctl list-units --type=service --state=active --no-legend --plain 'postgresql@*' 2>/dev/null | awk '{print $1; exit}')"; SC_PG_UNIT="${SC_PG_UNIT%.service}"
  local L="$SC_RUN_DIR/50-services.log"
  local since="${SC_SINCE:-24 hours ago}"

  sc_sh "$L" "system state" 'systemctl is-system-running; echo; systemctl --failed --no-pager'
  sc_sh "$L" "running services" 'systemctl list-units --type=service --state=running --no-pager --no-legend | awk "{print \$1}"'
  sc_sh "$L" "enabled but not running" \
    'comm -23 <(systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend | awk "{print \$1}" | sort) <(systemctl list-units --type=service --state=running,active --no-pager --no-legend | awk "{print \$1}" | sort) 2>/dev/null | head -20'
  sc_sh "$L" "timers" 'systemctl list-timers --all --no-pager 2>/dev/null | head -25'
  sc_sh "$L" "boot time breakdown" 'systemd-analyze 2>/dev/null; echo; systemd-analyze blame 2>/dev/null | head -12'

  local failed_count failed_list
  failed_count=$(sc_num "$(systemctl --failed --no-pager --no-legend 2>/dev/null | grep -c .)")
  failed_list=$(systemctl --failed --no-pager --no-legend 2>/dev/null | awk '{print $1}' | paste -sd', ' -)
  sc_metric "failed_units" "$failed_count"
  [ "${failed_count:-0}" -gt 0 ] && sc_finding major services "$failed_count systemd unit(s) in failed state: $failed_list"

  # Restart churn. A service silently restarting 40 times a night is invisible
  # in `systemctl status` but is a real problem.
  local R="$SC_RUN_DIR/51-restarts.log"
  echo "### units with NRestarts > 0" >> "$R"
  local u n churn=0 worst=""
  while read -r u; do
    n=$(sc_num "$(systemctl show "$u" -p NRestarts --value 2>/dev/null)")
    [ "$n" = "0" ] && continue
    printf '%-45s %s restarts\n' "$u" "$n" >> "$R"
    if [ "$n" -gt "$churn" ]; then churn="$n"; worst="$u"; fi
  done < <(systemctl list-units --type=service --state=running,failed --no-pager --no-legend 2>/dev/null | awk '{print $1}')
  [ "$churn" = "0" ] && echo "none" >> "$R"
  sc_metric "max_unit_restarts" "$churn"
  if   [ "${churn:-0}" -ge 20 ]; then sc_finding major services "$worst has restarted $churn times - it is in a crash loop"
  elif [ "${churn:-0}" -ge 5 ];  then sc_finding minor services "$worst has restarted $churn times"
  fi

  # Per-service errors for the units that actually matter on this box.
  local S="$SC_RUN_DIR/52-service-logs.log"
  local svc
  for svc in ${SC_WATCH_SERVICES:-ssh nginx docker ${SC_PG_UNIT:-postgresql} plexmediaserver ollama tailscaled cloudflared smbd cron systemd-timesyncd}; do
    systemctl list-unit-files "${svc}.service" --no-pager --no-legend >/dev/null 2>&1 || continue
    systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
    {
      echo "=== ${svc}: $(systemctl is-active "${svc}.service" 2>/dev/null)/$(systemctl is-enabled "${svc}.service" 2>/dev/null)  mem=$(systemctl show "${svc}.service" -p MemoryCurrent --value 2>/dev/null)"
    } >> "$S"
    sc_sh "$S" "${svc} errors" \
      "journalctl -u ${svc} -p 4 --since '$since' --no-pager -o cat 2>/dev/null || echo none"
  done

  return 0
}
