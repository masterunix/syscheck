#!/usr/bin/env bash
# Link health, reachability, and what is listening. A NIC that has started
# dropping frames is a classic aging-hardware symptom.
mod_network() {
  local L="$SC_RUN_DIR/70-network.log"

  sc_sh "$L" "interfaces" 'ip -br addr; echo; ip -br link'
  sc_sh "$L" "routes" 'ip route; echo; ip -6 route 2>/dev/null | head -5'
  sc_sh "$L" "interface counters" 'ip -s link'
  sc_sh "$L" "listening sockets" 'ss -tulnp 2>/dev/null | sort -k5'
  sc_sh "$L" "connection counts by state" \
    'ss -tan 2>/dev/null | awk "NR>1{print \$1}" | sort | uniq -c | sort -rn'
  sc_sh "$L" "DNS" 'resolvectl status 2>/dev/null | head -25 || cat /etc/resolv.conf'

  # Link speed / duplex: a port that has renegotiated down to 100Mb half-duplex
  # is usually a failing cable or NIC.
  local i
  for i in /sys/class/net/*; do
    local n; n=$(basename "$i")
    case "$n" in lo|docker*|veth*|br-*|tailscale*|virbr*|wl*) continue ;; esac
    # wireless has no meaningful speed/duplex in sysfs
    [ -d "$i/wireless" ] || [ -d "$i/phy80211" ] && continue
    [ -r "$i/speed" ] || continue
    local sp du op
    sp=$(cat "$i/speed" 2>/dev/null); du=$(cat "$i/duplex" 2>/dev/null); op=$(cat "$i/operstate" 2>/dev/null)
    printf '### %s: state=%s speed=%sMb duplex=%s\n' "$n" "$op" "$sp" "$du" >> "$L"
    [ "$op" = "up" ] && sc_metric "link_speed_$n" "${sp:-0}"
    if [ "$op" = "up" ] && [ -n "$sp" ] && [ "$sp" -gt 0 ] 2>/dev/null && [ "$sp" -lt 1000 ]; then
      sc_finding minor network "$n negotiated only ${sp}Mb ${du:-?}-duplex - suspect the cable or the switch port"
    fi
    # error counters
    local rxe txe rxd txd
    rxe=$(cat "$i/statistics/rx_errors" 2>/dev/null || echo 0)
    txe=$(cat "$i/statistics/tx_errors" 2>/dev/null || echo 0)
    rxd=$(cat "$i/statistics/rx_dropped" 2>/dev/null || echo 0)
    txd=$(cat "$i/statistics/tx_dropped" 2>/dev/null || echo 0)
    printf '    rx_errors=%s tx_errors=%s rx_dropped=%s tx_dropped=%s\n' "$rxe" "$txe" "$rxd" "$txd" >> "$L"
    sc_metric "net_${n}_rx_err" "$rxe"; sc_metric "net_${n}_tx_err" "$txe"
    if [ "$(( rxe + txe ))" -gt 1000 ]; then
      sc_finding major network "$n has $(( rxe + txe )) interface errors since boot"
    fi
  done

  # Reachability. Distinguishes "internet down" from "DNS broken".
  local C="$SC_RUN_DIR/71-connectivity.log"
  sc_sh "$C" "gateway ping" \
    'gw=$(ip route | awk "/^default/{print \$3; exit}"); echo "gateway=$gw"; [ -n "$gw" ] && ping -c3 -W2 "$gw" 2>&1 | tail -3'
  sc_sh "$C" "internet (1.1.1.1)" 'ping -c3 -W2 1.1.1.1 2>&1 | tail -3'
  sc_sh "$C" "DNS resolution" 'getent hosts github.com || echo "DNS FAILED"'
  sc_sh "$C" "NTP sync" 'timedatectl show -p NTPSynchronized -p TimeUSec 2>/dev/null; timedatectl 2>/dev/null | grep -E "synchronized|Time zone"'

  # Evaluate these directly. Grepping $C would also match the echoed command
  # line that sc_sh writes above each result.
  getent hosts github.com >/dev/null 2>&1 || \
    sc_finding major network "DNS resolution is failing"

  local gw
  gw=$(ip route | awk '/^default/{print $3; exit}')
  if [ -n "$gw" ] && ! ping -c3 -W2 "$gw" >/dev/null 2>&1; then
    sc_finding major network "No response from the default gateway ($gw)"
  fi
  if ! ping -c3 -W2 1.1.1.1 >/dev/null 2>&1; then
    sc_finding major network "No route to the internet (1.1.1.1 unreachable)"
  fi

  # Clock drift points at a dead CMOS battery, which on a 2012 board is likely.
  local synced
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  sc_metric "ntp_synced" "${synced:-unknown}"
  [ "$synced" = "no" ] && sc_finding minor power "Clock is not NTP-synchronised - on a board this age, suspect the CMOS battery"

  # Overlay networks this box depends on
  command -v tailscale >/dev/null && sc_sh "$L" "tailscale" 'timeout 10 tailscale status 2>&1 | head -12'
  systemctl is-active cloudflared >/dev/null 2>&1 && \
    sc_sh "$L" "cloudflared tunnel" "journalctl -u cloudflared --since '${SC_SINCE:-24 hours ago}' --no-pager -o cat 2>/dev/null | grep -iE 'error|failed|disconnect|reconnect' | tail -12 || echo none"

  return 0
}
