#!/usr/bin/env bash
# Compare tonight against the previous run. On hardware this old the *rate of
# change* says far more than any single reading: 4 reallocated sectors is a
# worn drive, 4 more since yesterday is a drive that will not survive the week.
mod_trend() {
  local L="$SC_RUN_DIR/99-trend.log"
  local prev; prev=$(sc_prev_run_dir) || { echo "no previous run to compare against (this is the first)" > "$L"; return 0; }

  echo "### comparing $(basename "$SC_RUN_DIR") against $(basename "$prev")" > "$L"
  printf '\n%-24s %14s %14s %12s\n' "METRIC" "PREVIOUS" "NOW" "DELTA" >> "$L"
  printf '%s\n' "--------------------------------------------------------------------" >> "$L"

  local key now was delta
  while IFS=$'\t' read -r key now; do
    was=$(sc_metric_get "$prev" "$key")
    [ -z "$was" ] && continue
    if [[ "$now" =~ ^-?[0-9]+$ ]] && [[ "$was" =~ ^-?[0-9]+$ ]]; then
      delta=$(( now - was ))
      [ "$delta" -gt 0 ] && delta="+$delta"
    elif [[ "$now" =~ ^-?[0-9.]+$ ]] && [[ "$was" =~ ^-?[0-9.]+$ ]]; then
      delta=$(echo "scale=2; $now - $was" | bc 2>/dev/null)
    else
      [ "$now" = "$was" ] && delta="same" || delta="CHANGED"
    fi
    printf '%-24s %14s %14s %12s\n' "$key" "$was" "$now" "$delta" >> "$L"
  done < "$SC_RUN_DIR/metrics.tsv"

  # --- the deltas that mean something ------------------------------------
  sc_delta() {  # sc_delta <key> -> integer change, empty if not comparable
    local k="$1" a b
    a=$(sc_metric_get "$prev" "$k"); b=$(sc_metric_get "$SC_RUN_DIR" "$k")
    [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] || return 1
    echo $(( b - a ))
  }

  local d
  # Any growth in these three means the platters are actively shedding sectors.
  for k in smart_reall smart_pending smart_offline; do
    d=$(sc_delta "$k") || continue
    if [ "$d" -gt 0 ]; then
      sc_finding critical storage \
        "$k grew by $d since the last check - the drive is losing sectors *right now*, not historically" 1
    fi
  done

  d=$(sc_delta "smart_crc") && [ "${d:-0}" -gt 0 ] && \
    sc_finding major storage "SATA CRC errors grew by $d since yesterday - reseat the data cable"

  d=$(sc_delta "ata_errors") && [ "${d:-0}" -gt 10 ] && \
    sc_finding major kernel "SATA errors up by $d since the last check"

  d=$(sc_delta "cpu_throttle_events") && [ "${d:-0}" -gt 0 ] && \
    sc_finding major thermal "$d new thermal throttle events since yesterday - it is overheating under normal load"

  d=$(sc_delta "edac_ce") && [ "${d:-0}" -gt 0 ] && \
    sc_finding major memory "$d new correctable memory errors since yesterday"

  # Disk fill rate -> days until full. The single most actionable trend number.
  local avail_now avail_prev used_per_day days
  avail_now=$(sc_metric_get "$SC_RUN_DIR" "root_avail_kb")
  avail_prev=$(sc_metric_get "$prev" "root_avail_kb")
  if [[ "$avail_now" =~ ^[0-9]+$ ]] && [[ "$avail_prev" =~ ^[0-9]+$ ]]; then
    used_per_day=$(( avail_prev - avail_now ))
    if [ "$used_per_day" -gt 0 ]; then
      days=$(( avail_now / used_per_day ))
      echo "" >> "$L"
      echo "### disk fill rate: ${used_per_day}KB/day -> approx ${days} days until full" >> "$L"
      sc_metric "days_until_disk_full" "$days"
      if   [ "$days" -le 3 ];  then sc_finding critical storage "At the current fill rate the root filesystem is full in ~${days} days" 1
      elif [ "$days" -le 14 ]; then sc_finding major storage "At the current fill rate the root filesystem is full in ~${days} days"
      elif [ "$days" -le 45 ]; then sc_finding minor storage "At the current fill rate the root filesystem is full in ~${days} days"
      fi
    fi
  fi

  # Long-horizon view for Claude: append tonight to a rolling CSV.
  local hist="$SC_HISTORY"
  if [ ! -f "$hist" ]; then
    printf 'date\tcpu_temp\tsmart_reall\tsmart_pending\tsmart_crc\tpoh\troot_pct\tload1\tata_err\tfailed_units\n' > "$hist"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%F)" \
    "$(sc_metric_get "$SC_RUN_DIR" cpu_temp_c)" \
    "$(sc_metric_get "$SC_RUN_DIR" smart_reall)" \
    "$(sc_metric_get "$SC_RUN_DIR" smart_pending)" \
    "$(sc_metric_get "$SC_RUN_DIR" smart_crc)" \
    "$(sc_metric_get "$SC_RUN_DIR" smart_poh)" \
    "$(sc_metric_get "$SC_RUN_DIR" root_used_pct)" \
    "$(sc_metric_get "$SC_RUN_DIR" load1)" \
    "$(sc_metric_get "$SC_RUN_DIR" ata_errors)" \
    "$(sc_metric_get "$SC_RUN_DIR" failed_units)" >> "$hist"

  echo "" >> "$L"
  echo "### rolling history (last 30 runs)" >> "$L"
  { head -1 "$hist"; tail -30 "$hist" | grep -v '^date'; } | column -t -s$'\t' >> "$L" 2>/dev/null || tail -31 "$hist" >> "$L"

  return 0
}
