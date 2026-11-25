#!/usr/bin/env bash
# Gather everything into $SC_RUN_DIR. Runs as root, from run.sh.
# Deliberately does NOT use `set -e`: one broken probe must never abort the
# rest of the sweep.
set -uo pipefail

SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

[ -z "${SC_RUN_DIR:-}" ] && { echo "SC_RUN_DIR not set" >&2; exit 1; }
mkdir -p "$SC_RUN_DIR"

for m in "$SC_PREFIX"/modules/*.sh; do . "$m"; done

# Only look at logs since the previous run so nothing is double-counted.
prev=$(sc_prev_run_dir 2>/dev/null || true)
if [ -n "$prev" ] && [ -f "$prev/.finished" ]; then
  prev_epoch=$(stat -c %Y "$prev/.finished")
  # Cap the lookback. If runs have been failing for weeks, "since the last
  # success" would scan the entire journal every night -- the output is still
  # tail-limited so Claude's input stays bounded, but the query is not free.
  oldest=$(( $(date +%s) - ${SC_MAX_LOOKBACK_DAYS:-7} * 86400 ))
  [ "$prev_epoch" -lt "$oldest" ] && prev_epoch="$oldest"
  SC_SINCE="$(date -d "@$prev_epoch" '+%Y-%m-%d %H:%M:%S')"
else
  SC_SINCE="24 hours ago"
fi
export SC_SINCE
sc_log "log window: since $SC_SINCE"

# --- SMART self-test: start it first, read it last ----------------------
# A short test takes about two minutes on a drive this size. Kicking it off up
# front means it finishes while the rest of the sweep runs, costing us nothing.
SELFTEST_STARTED=0
if [ "$(id -u)" = "0" ] && command -v smartctl >/dev/null; then
  if smartctl -c "$SC_DISK" 2>/dev/null | grep -qi "Self-test routine in progress"; then
    sc_log "a SMART self-test is already running; not starting another"
  elif smartctl -t short "$SC_DISK" >/dev/null 2>&1; then
    SELFTEST_STARTED=1
    sc_log "SMART short self-test started on $SC_DISK"
  else
    sc_log "could not start SMART self-test"
  fi
fi

# --- run every module ---------------------------------------------------
# After every module, refresh the banner. Someone logging in at 05:03 should
# see that faults have already been found, not a stale "no faults yet".
refresh_state() {
  local worst="none" sev
  if [ -s "$SC_RUN_DIR/findings.tsv" ]; then
    while IFS=$'\t' read -r sev _ _ _; do
      worst=$(sc_sev_max "$worst" "$sev")
    done < "$SC_RUN_DIR/findings.tsv"
  fi
  sc_state_write "running" "$worst" \
    "Collecting diagnostics — ${1:-} done, $(( ${2:-0} )) of ${TOTAL_MODULES:-10} checks complete."
}

# Each module runs in a subshell with its own overall timeout. A module that
# aborts -- an unbound variable, a bad exit, a probe wedged on a dying disk --
# takes only itself down, never the rest of the sweep. Findings and metrics are
# file appends, so nothing is lost by the isolation.
run_module() {
  local fn="$1" label="$2" t0 t1 rc
  t0=$(sc_epoch)
  sc_log "-> $label"
  ( timeout -k 20 "${SC_MODULE_TIMEOUT:-300}" bash -c "
      set -uo pipefail
      . '$SC_PREFIX/lib/common.sh'
      for m in '$SC_PREFIX'/modules/*.sh; do . \"\$m\"; done
      $fn
    " )
  rc=$?
  t1=$(sc_epoch)
  case "$rc" in
    0)        sc_log "   $label ok ($((t1-t0))s)" ;;
    124|137)  sc_log "   $label TIMED OUT after $((t1-t0))s (partial data kept)"
              sc_finding minor system "The '$label' check timed out; its data is incomplete" ;;
    *)        sc_log "   $label exited rc=$rc after $((t1-t0))s (continuing)" ;;
  esac
  MODULES_DONE=$(( ${MODULES_DONE:-0} + 1 ))
  refresh_state "$label" "$MODULES_DONE"
}

TOTAL_MODULES=11
MODULES_DONE=0

run_module mod_hardware "hardware/thermal"
run_module mod_storage  "storage/SMART"
run_module mod_memory   "memory"
run_module mod_logs     "kernel+journal"
run_module mod_services "systemd services"
run_module mod_docker   "docker"
run_module mod_network  "network"
run_module mod_security "security/updates"
SC_MODULE_TIMEOUT=600 run_module mod_apps     "applications"
run_module mod_audio    "alarm audio path"

# --- collect the self-test result ---------------------------------------
if [ "$SELFTEST_STARTED" = "1" ]; then
  S="$SC_RUN_DIR/21-smart.log"
  sc_log "waiting for SMART self-test to finish (up to 6 min)"
  for _ in $(seq 1 36); do
    smartctl -c "$SC_DISK" 2>/dev/null | grep -qi "Self-test routine in progress" || break
    sleep 10
  done
  {
    echo "### SMART self-test result (started this run)"
    smartctl -l selftest "$SC_DISK" 2>&1 | head -12
  } >> "$S"

  latest=$(smartctl -l selftest "$SC_DISK" 2>/dev/null | awk '/^# *1/{print; exit}')
  echo "### latest self-test: $latest" >> "$S"

  # Only trust entry #1 as *tonight's* result if its lifetime hour matches the
  # drive's current power-on hours. The self-test log keeps old entries forever,
  # so without this check a test that failed to register would leave a months-old
  # failure sitting at #1 and sound the alarm every night.
  poh_now=$(smartctl -A "$SC_DISK" 2>/dev/null | awk '$1==9{print $10; exit}' | tr -dc '0-9')
  test_hour=$(echo "$latest" | awk '{print $(NF-1)}' | tr -dc '0-9')
  is_tonight=0
  if [[ "$poh_now" =~ ^[0-9]+$ ]] && [[ "$test_hour" =~ ^[0-9]+$ ]] \
     && [ $(( poh_now - test_hour )) -le 2 ]; then
    is_tonight=1
  fi
  echo "### entry is from this run: $is_tonight (drive at ${poh_now}h, entry at ${test_hour}h)" >> "$S"

  if [ "$is_tonight" = "1" ] && echo "$latest" | grep -qi "Completed without error"; then
    sc_log "SMART self-test PASSED"
    sc_metric "selftest" "pass"
  elif [ "$is_tonight" = "1" ]; then
    sc_log "SMART self-test FAILED"
    sc_metric "selftest" "fail"
    sc_finding critical storage \
      "Tonight's SMART short self-test FAILED: ${latest#*  } - the drive failed its own diagnostic just now" 1
  else
    sc_log "self-test result did not register for this run; the recency rule in 20-storage will judge the log"
    sc_metric "selftest" "did-not-register"
  fi
fi

# trend runs last: it needs every other module's metrics to be on disk
run_module mod_trend "trend vs previous run"

# Compress the full archive. It is written once and read rarely, compresses
# about 10:1, and the disk is the resource worth protecting.
# zcat/zgrep read it fine when something actually needs digging into.
if [ -d "$SC_RUN_DIR/full" ]; then
  before=$(du -sk "$SC_RUN_DIR/full" 2>/dev/null | cut -f1)
  gzip -9 -f "$SC_RUN_DIR"/full/*.log 2>/dev/null
  after=$(du -sk "$SC_RUN_DIR/full" 2>/dev/null | cut -f1)
  sc_log "full archive compressed: ${before}KB -> ${after}KB"
fi

touch "$SC_RUN_DIR/.finished"
sc_log "collection complete"
