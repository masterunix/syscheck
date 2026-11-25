#!/usr/bin/env bash
# Common workloads, each checked only when it is present.
mod_apps() {
  # The cluster unit is named after the major version (postgresql@16-main).
  SC_PG_UNIT="$(systemctl list-units --type=service --state=active --no-legend --plain 'postgresql@*' 2>/dev/null | awk '{print $1; exit}')"
  SC_PG_UNIT="${SC_PG_UNIT%.service}"
  local L="$SC_RUN_DIR/90-apps.log"
  local since="${SC_SINCE:-24 hours ago}"

  # --- nginx ---
  if systemctl is-active nginx >/dev/null 2>&1; then
    sc_sh "$L" "nginx config test" 'nginx -t 2>&1'
    sc_sh "$L" "nginx error log" \
      'tail -60 /var/log/nginx/error.log 2>/dev/null | grep -viE "favicon|robots.txt" | tail -25 || echo "unreadable"'
    sc_sh "$L" "nginx 5xx in access log" \
      'for f in /var/log/nginx/access.log; do [ -r "$f" ] && awk "\$9 ~ /^5/ {print \$9}" "$f" 2>/dev/null | sort | uniq -c | sort -rn | head; done || echo none'
    # Only meaningful as root: an unprivileged `nginx -t` cannot open
    # /run/nginx.pid and reports failure regardless of the config.
    if [ "$(id -u)" = "0" ]; then
      nginx -t >/dev/null 2>&1 || \
        sc_finding major apps "nginx configuration is invalid - a reload would take the site down"
    fi
    local n5xx
    n5xx=$(sc_num "$(awk '$9 ~ /^5/' /var/log/nginx/access.log 2>/dev/null | wc -l)")
    sc_metric "nginx_5xx" "${n5xx:-0}"
    [ "${n5xx:-0}" -ge 100 ] && sc_finding minor apps "nginx served ${n5xx} 5xx responses in the current access log"
  fi

  # --- postgresql ---
  if systemctl is-active ${SC_PG_UNIT:-postgresql} >/dev/null 2>&1; then
    sc_sh "$L" "postgres status" 'pg_isready 2>&1'
    sc_sh "$L" "postgres errors" \
      "journalctl -u ${SC_PG_UNIT:-postgresql} --since '$since' --no-pager -o cat 2>/dev/null | grep -iE 'error|fatal|panic|could not|deadlock|corrupt' || echo none"
    # Ask the server where its data lives. The path carries the major version
    # on Debian and Ubuntu (/var/lib/postgresql/18/main) and differs on Arch.
    sc_sh "$L" "postgres data size" \
      'd=$(su - postgres -c "psql -tAc \"show data_directory\"" 2>/dev/null); [ -n "$d" ] || d=$(ls -d /var/lib/postgresql/*/main /var/lib/postgres/data 2>/dev/null | sort -V | tail -1); if [ -n "$d" ]; then du -sh "$d" 2>/dev/null || echo "unreadable: $d"; else echo "data directory not found"; fi'
    if [ "$(id -u)" = "0" ]; then
      sc_sh "$L" "postgres databases" \
        'su - postgres -c "psql -tAc \"select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by pg_database_size(datname) desc;\"" 2>/dev/null || echo unavailable'
      sc_sh "$L" "postgres long-running queries" \
        'su - postgres -c "psql -tAc \"select pid, now()-query_start as dur, state, left(query,80) from pg_stat_activity where state<>'"'"'idle'"'"' and now()-query_start > interval '"'"'5 minutes'"'"';\"" 2>/dev/null || echo unavailable'
    fi
    pg_isready >/dev/null 2>&1 || sc_finding major apps "PostgreSQL is not accepting connections"
    journalctl -u ${SC_PG_UNIT:-postgresql} --since "$since" --no-pager 2>/dev/null | grep -qiE 'PANIC|corrupt|invalid page' && \
      sc_finding critical apps "PostgreSQL reported corruption or a PANIC - database integrity is at risk" 1
  fi

  # --- plex / ollama ---
  systemctl is-active plexmediaserver >/dev/null 2>&1 && \
    sc_sh "$L" "plex" "systemctl status plexmediaserver --no-pager -l 2>/dev/null | head -12"
  systemctl is-active ollama >/dev/null 2>&1 && {
    sc_sh "$L" "ollama" "journalctl -u ollama --since '$since' --no-pager -o cat 2>/dev/null | grep -iE 'error|failed|out of memory' | tail -12 || echo none"
    sc_sh "$L" "ollama models on disk" 'du -sh /usr/share/ollama/.ollama/models 2>/dev/null || du -sh ~/.ollama/models 2>/dev/null || echo unreadable'
  }

  # --- what is eating the disk ---
  local D="$SC_RUN_DIR/91-disk-hogs.log"
  # These two walk every inode on the disk -- a lot of seeking for a
  # mechanical drive -- so each gets an explicit generous budget instead of
  # the default 25s. `du` runs first: it warms the dentry cache that makes
  # the `find` afterwards far cheaper.
  SC_CMD_TIMEOUT=120 sc_sh "$D" "largest directories under /" \
    'du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -30'
  SC_CMD_TIMEOUT=90 sc_sh "$D" "largest files over 500MB" \
    'find / -xdev -type f -size +500M -printf "%s\t%p\n" 2>/dev/null | sort -rn | head -20 | awk "{printf \"%.1fG\t%s\n\", \$1/1073741824, \$2}"'
  sc_sh "$D" "log directory sizes" 'du -sh /var/log/* 2>/dev/null | sort -rh | head -15'
  sc_sh "$D" "journal usage" 'journalctl --disk-usage'
  sc_sh "$D" "apt cache" 'du -sh /var/cache/apt 2>/dev/null'
  sc_sh "$D" "space held by deleted-but-open files" \
    'lsof -nP 2>/dev/null | awk "/deleted/{s+=\$7} END{printf \"%.0f MB still held by deleted-but-open files\\n\", s/1048576}" || echo "lsof unavailable"' 
  sc_sh "$D" "old snap revisions" \
    'snap list --all 2>/dev/null | awk "/disabled/{print \$1, \$3}" | head -20; echo "(disabled revisions are dead weight)"'

  # --- processes ---
  local P="$SC_RUN_DIR/92-processes.log"
  sc_sh "$P" "top by CPU" 'ps -eo pid,ppid,pcpu,pmem,etimes,stat,comm --sort=-pcpu | head -16'
  sc_sh "$P" "zombies" 'ps -eo stat,pid,ppid,comm | awk "\$1 ~ /Z/" || echo none'
  sc_sh "$P" "process/thread/fd totals" \
    'echo "processes: $(ps -e --no-headers | wc -l)"; echo "threads  : $(ps -eLf --no-headers 2>/dev/null | wc -l)"; echo "open fds : $(cat /proc/sys/fs/file-nr)"'
  sc_sh "$P" "load average vs cores" \
    'echo "load: $(cat /proc/loadavg)"; echo "cores: $(nproc)"'

  local zombies load1 cores
  zombies=$(sc_num "$(ps -eo stat --no-headers | grep -c '^Z')")
  load1=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc)
  sc_metric "zombies" "$zombies"
  sc_metric "load1" "$load1"
  [ "${zombies:-0}" -ge 20 ] && sc_finding minor system "$zombies zombie processes - a parent is not reaping its children"
  if [ "$(echo "$load1 > $cores * 2" | bc -l 2>/dev/null)" = "1" ]; then
    sc_finding major system "Load average $load1 on $cores cores during the scheduled run - something is working much harder than it should be"
  fi

  return 0
}
