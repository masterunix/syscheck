#!/usr/bin/env bash
# Docker: container health, restart loops, and how much of the 500GB disk the
# images and volumes have quietly eaten.
mod_docker() {
  command -v docker >/dev/null || return 0
  local L="$SC_RUN_DIR/60-docker.log"

  # With socket activation, asking a stopped daemon anything starts it. A
  # health check must not change what is running, so skip it instead.
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    echo "docker is installed but its service is not running; skipped" >> "$L"
    return 0
  fi

  docker info >/dev/null 2>&1 || { echo "docker daemon unreachable" >> "$L"
    sc_finding major docker "Docker daemon is not responding"; return 0; }

  sc_sh "$L" "containers" \
    'docker ps -a --format "table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}" | head -40; echo "(total: $(docker ps -aq | wc -l) containers)"'
  sc_sh "$L" "resource usage" \
    'timeout 20 docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"'
  sc_sh "$L" "disk consumed by docker" 'docker system df -v 2>/dev/null | head -40'
  sc_sh "$L" "daemon errors" \
    "journalctl -u docker --since '${SC_SINCE:-24 hours ago}' -p 4 --no-pager -o cat 2>/dev/null || echo none"

  local total running unhealthy exited
  total=$(sc_num "$(docker ps -aq 2>/dev/null | wc -l)")
  running=$(sc_num "$(docker ps -q 2>/dev/null | wc -l)")
  unhealthy=$(sc_num "$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)")
  exited=$(sc_num "$(docker ps -a --filter status=exited -q 2>/dev/null | wc -l)")
  sc_metric "docker_total" "$total"
  sc_metric "docker_running" "$running"
  sc_metric "docker_unhealthy" "$unhealthy"

  if [ "${unhealthy:-0}" -gt 0 ]; then
    local names; names=$(docker ps --filter health=unhealthy --format '{{.Names}}' | paste -sd', ' -)
    sc_finding major docker "$unhealthy container(s) reporting unhealthy: $names"
  fi

  # Restart-loop detection
  local c rc
  local R="$SC_RUN_DIR/61-docker-restarts.log"
  for c in $(docker ps -aq 2>/dev/null); do
    rc=$(sc_num "$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)")
    [ "${rc:-0}" -eq 0 ] && continue
    printf '%-28s restarts=%s state=%s\n' \
      "$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /)" "$rc" \
      "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" >> "$R"
    [ "$rc" -ge 10 ] && sc_finding major docker "Container $(docker inspect -f '{{.Name}}' "$c" | tr -d /) has restarted $rc times"
  done
  [ -s "$R" ] || echo "no container restarts recorded" >> "$R"

  # Tail errors from each running container so Claude has something to chew on.
  local T="$SC_RUN_DIR/62-container-logs.log"
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    echo "=== $c" >> "$T"
    timeout 15 docker logs --since "${SC_SINCE_DOCKER:-24h}" "$c" 2>&1 \
      | grep -iE 'error|fatal|panic|exception|failed|refused|timeout|denied' \
      >> "$T" 2>/dev/null || echo "  (none)" >> "$T"
    echo >> "$T"
  done

  return 0
}
