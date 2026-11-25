#!/usr/bin/env bash
# Disk health. This is the module that matters most: sda is a WD5000AAKX, a
# spinning 500GB drive from roughly 2012, and it is the *only* storage in the
# box. When it goes, everything goes with it.
mod_storage() {
  local L="$SC_RUN_DIR/20-storage.log"
  local S="$SC_RUN_DIR/21-smart.log"

  sc_sh "$L" "block devices" 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,ROTA | grep -v "^loop"'
  sc_sh "$L" "filesystem usage" 'df -hT -x tmpfs -x devtmpfs -x squashfs'
  sc_sh "$L" "inode usage" 'df -i -x tmpfs -x devtmpfs -x squashfs'
  sc_sh "$L" "mount options" 'findmnt -t ext4,xfs,btrfs,vfat -o TARGET,SOURCE,FSTYPE,OPTIONS'
  sc_sh "$L" "swap" 'swapon --show; cat /proc/swaps'

  # Root filesystem fill level and growth
  local root_pct root_avail
  root_pct=$(sc_num "$(df --output=pcent / | tail -1)")
  root_avail=$(sc_num "$(df --output=avail / | tail -1)")   # KiB
  sc_metric "root_used_pct" "$root_pct"
  sc_metric "root_avail_kb" "$root_avail"
  if   [ "$root_pct" -ge 95 ]; then sc_finding critical storage "Root filesystem ${root_pct}% full - services will start failing" 1
  elif [ "$root_pct" -ge 90 ]; then sc_finding major storage "Root filesystem ${root_pct}% full"
  elif [ "$root_pct" -ge 80 ]; then sc_finding minor storage "Root filesystem ${root_pct}% full"
  fi

  local inode_pct; inode_pct=$(sc_num "$(df -i / | awk 'NR==2{print $5}')")
  sc_metric "root_inode_pct" "$inode_pct"
  [ "${inode_pct:-0}" -ge 85 ] && sc_finding major storage "Root inodes ${inode_pct}% used"

  # ext4 internal state. 'clean' is what we want; anything else means the
  # kernel flagged corruption.
  if [ "$(id -u)" = "0" ] && command -v tune2fs >/dev/null; then
    sc_sh "$L" "ext4 superblock state ($SC_ROOT_DEV)" \
      "tune2fs -l $SC_ROOT_DEV 2>/dev/null | grep -E 'Filesystem state|Errors behavior|Mount count|Maximum mount|Last checked|Check interval|Lifetime writes|Free blocks|Filesystem created'"
    local fsstate
    fsstate=$(tune2fs -l "$SC_ROOT_DEV" 2>/dev/null | awk -F: '/Filesystem state/{gsub(/ /,"",$2);print $2}')
    sc_metric "fs_state" "${fsstate:-unknown}"
    case "$fsstate" in
      clean) : ;;
      "") : ;;
      *) sc_finding critical storage "ext4 on $SC_ROOT_DEV reports state '$fsstate' - filesystem corruption flagged" 1 ;;
    esac
  fi

  # Read-only remount is the kernel's last-ditch response to write errors.
  if grep -qE ' / .*[( ,]ro[, )]' /proc/mounts; then
    sc_finding critical storage "Root filesystem has been remounted READ-ONLY - the kernel hit write errors" 1
  fi

  # --- SMART ------------------------------------------------------------
  if ! command -v smartctl >/dev/null; then
    echo "smartctl not installed - SMART data unavailable" >> "$S"
    sc_finding major storage "smartctl is not installed; disk health cannot be read"
    return 0
  fi
  if [ "$(id -u)" != "0" ]; then
    echo "not root - SMART requires privileges" >> "$S"
    return 0
  fi

  local dev="$SC_DISK"
  sc_run "$S" "SMART info" -- smartctl -i "$dev"
  sc_run "$S" "SMART health" -- smartctl -H "$dev"
  SC_CMD_TIMEOUT=40 sc_run "$S" "SMART all attributes" -- smartctl -x "$dev"
  sc_run "$S" "SMART error log" -- smartctl -l error "$dev"
  sc_run "$S" "SMART selftest log" -- smartctl -l selftest "$dev"

  # Overall verdict line
  if smartctl -H "$dev" 2>/dev/null | grep -qiE "result:.*(FAILED|FAILING)"; then
    sc_finding critical storage "SMART overall-health self-assessment: FAILED - the drive is reporting its own imminent death" 1
  fi

  # Pull the attributes that actually predict failure. Backblaze's long-running
  # study found five that matter; these are those five plus temperature and
  # power-on hours for context.
  local attrs="$SC_RUN_DIR/22-smart-key-attrs.txt"
  local raw_dump; raw_dump=$(smartctl -A "$dev" 2>/dev/null)

  sc_attr() {  # sc_attr <id> <name>  -> raw value
    echo "$raw_dump" | awk -v id="$1" '$1==id {print $10; exit}' | tr -dc '0-9' 
  }

  local reall pending offline uncorr crc poh temp_d spin_retry load_cycle start_stop
  reall=$(sc_attr 5);      pending=$(sc_attr 197); offline=$(sc_attr 198)
  uncorr=$(sc_attr 187);   crc=$(sc_attr 199);     poh=$(sc_attr 9)
  temp_d=$(sc_attr 194);   spin_retry=$(sc_attr 10)
  load_cycle=$(sc_attr 193); start_stop=$(sc_attr 4)

  # Attribute 194 raw often packs min/max into high bits; keep only a sane value.
  [ -n "$temp_d" ] && [ "$temp_d" -gt 200 ] 2>/dev/null && temp_d=$(echo "$raw_dump" | awk '$1==194{print $10; exit}' | awk '{print $1}' | tr -dc '0-9')

  {
    echo "device            : $dev  ($(cat /sys/block/$SC_DISK_NAME/device/model 2>/dev/null))"
    printf '%-34s %s\n' "5   Reallocated_Sector_Ct"   "${reall:-n/a}"
    printf '%-34s %s\n' "197 Current_Pending_Sector"  "${pending:-n/a}"
    printf '%-34s %s\n' "198 Offline_Uncorrectable"   "${offline:-n/a}"
    printf '%-34s %s\n' "187 Reported_Uncorrect"      "${uncorr:-n/a}"
    printf '%-34s %s\n' "199 UDMA_CRC_Error_Count"    "${crc:-n/a}"
    printf '%-34s %s\n' "10  Spin_Retry_Count"        "${spin_retry:-n/a}"
    printf '%-34s %s\n' "9   Power_On_Hours"          "${poh:-n/a}"
    printf '%-34s %s\n' "4   Start_Stop_Count"        "${start_stop:-n/a}"
    printf '%-34s %s\n' "193 Load_Cycle_Count"        "${load_cycle:-n/a}"
    printf '%-34s %s\n' "194 Temperature_Celsius"     "${temp_d:-n/a}"
    [ -n "$poh" ] && echo "power-on years    : $(echo "scale=2; $poh/8760" | bc 2>/dev/null)"
  } > "$attrs"

  local k v
  for k in reall pending offline uncorr crc poh temp_d spin_retry load_cycle; do
    v="${!k}"; [ -n "$v" ] && sc_metric "smart_$k" "$v"
  done

  # Thresholds. Any non-zero value in the first four is a real signal on a
  # drive this old -- these attributes sit at zero for the whole healthy life
  # of a disk and only move when the platters are going.
  [ "${pending:-0}" -gt 0 ] 2>/dev/null && \
    sc_finding critical storage "SMART Current_Pending_Sector = $pending - sectors the drive cannot read and has not yet remapped" 1
  [ "${offline:-0}" -gt 0 ] 2>/dev/null && \
    sc_finding critical storage "SMART Offline_Uncorrectable = $offline - unrecoverable read errors, data loss is already possible" 1
  [ "${uncorr:-0}" -gt 0 ] 2>/dev/null && \
    sc_finding major storage "SMART Reported_Uncorrect = $uncorr uncorrectable errors reported to the host"
  if [ "${reall:-0}" -gt 0 ] 2>/dev/null; then
    if [ "${reall}" -ge 40 ]; then
      sc_finding critical storage "SMART Reallocated_Sector_Ct = $reall - the drive has burned through its spare sector pool" 1
    else
      sc_finding major storage "SMART Reallocated_Sector_Ct = $reall - bad sectors have been remapped; the drive is degrading"
    fi
  fi
  [ "${crc:-0}" -gt 0 ] 2>/dev/null && \
    sc_finding minor storage "SMART UDMA_CRC_Error_Count = $crc - usually a loose or aging SATA cable rather than the drive itself"
  [ "${spin_retry:-0}" -gt 0 ] 2>/dev/null && \
    sc_finding critical storage "SMART Spin_Retry_Count = $spin_retry - the motor is struggling to spin the platters up" 1
  if [ -n "${temp_d:-}" ]; then
    [ "$temp_d" -ge 60 ] 2>/dev/null && sc_finding major storage "Drive temperature ${temp_d}C - too hot for a mechanical disk"
    [ "$temp_d" -ge 50 ] 2>/dev/null && [ "$temp_d" -lt 60 ] && sc_finding minor storage "Drive temperature ${temp_d}C - warm"
  fi

  # Self-test history. A failed test is a direct warning, but the log keeps the
  # last 21 entries indefinitely -- a failure from months ago is drive history,
  # not tonight's news. Weigh it by how long ago it happened, measured in
  # power-on hours, so a stale entry cannot sound the alarm every single night.
  local st_line st_hours st_age
  st_line=$(smartctl -l selftest "$dev" 2>/dev/null | \
    grep -iE "read failure|Completed: (unknown|electrical|servo|handling|failure)" | head -1)

  if [ -n "$st_line" ]; then
    echo "### most recent FAILED self-test: $st_line" >> "$attrs"
    # Layout: "# N  <description>  Completed: <reason>  <rem%>  <lifetime_hours>  <lba>"
    st_hours=$(echo "$st_line" | awk '{print $(NF-1)}' | tr -dc '0-9')
    if [[ "$st_hours" =~ ^[0-9]+$ ]] && [[ "${poh:-}" =~ ^[0-9]+$ ]]; then
      st_age=$(( poh - st_hours ))
      sc_metric "smart_selftest_fail_age_h" "$st_age"
      echo "### that failure was $st_age power-on hours ago (~$(( st_age / 24 )) days)" >> "$attrs"

      if [ "$st_age" -le 168 ]; then
        # Within the last week of runtime, and the drive is still failing.
        sc_finding critical storage \
          "SMART self-test failed ${st_age}h ago (lifetime hour $st_hours of $poh) - the drive is failing its own diagnostic right now" 1
      elif [ "$st_age" -le 1000 ]; then
        sc_finding major storage \
          "SMART self-test failed $(( st_age / 24 )) days ago at lifetime hour $st_hours; it has not failed since, but this drive has a history of read failures"
      else
        # Historical. Only meaningful alongside sectors actually going bad --
        # and if those had gone bad, the attribute checks above would have
        # already fired on their own.
        sc_finding minor storage \
          "A SMART self-test failed $(( st_age / 24 )) days ago (lifetime hour $st_hours), but no sectors have been reallocated or gone pending since - the drive appears to have recovered"
      fi
    else
      sc_finding major storage "SMART self-test log contains a failed test: $st_line"
    fi
  fi

  # --- I/O behaviour ----------------------------------------------------
  local IO="$SC_RUN_DIR/23-io.log"
  sc_sh "$IO" "iostat (5s sample)" 'iostat -xdz 5 2 2>/dev/null | tail -n +4'
  sc_sh "$IO" "disk latency now" "cat /sys/block/$SC_DISK_NAME/stat; echo '(reads_completed reads_merged sectors_read ms_reading writes_completed ... io_in_progress ms_doing_io weighted_ms)'"
  sc_sh "$IO" "dirty/writeback" 'grep -E "Dirty|Writeback" /proc/meminfo'
  sc_sh "$IO" "processes in uninterruptible sleep (D state)" \
    'ps -eo state,pid,comm,wchan:24 | awk "\$1==\"D\"" || echo none'
  [ "$(id -u)" = "0" ] && command -v hdparm >/dev/null && \
    sc_sh "$IO" "drive power mode + cache" "hdparm -C $SC_DISK 2>/dev/null; hdparm -W $SC_DISK 2>/dev/null"

  # A drive that has gone bad usually shows up as sustained high await first.
  local await
  await=$(iostat -xd 5 2 2>/dev/null | awk -v d="$SC_DISK_NAME" '$1==d{a=$NF} END{print a}')
  local util
  util=$(iostat -xd 5 2 2>/dev/null | awk -v d="$SC_DISK_NAME" '$1==d{u=$NF} END{print u}')

  # D-state processes stuck on a dying disk
  local dcount; dcount=$(sc_num "$(ps -eo state --no-headers | grep -c '^D')")
  sc_metric "dstate_procs" "$dcount"
  [ "${dcount:-0}" -ge 5 ] && sc_finding major storage "$dcount processes stuck in uninterruptible I/O wait - the disk is not keeping up"

  return 0
}
