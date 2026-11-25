#!/usr/bin/env bash
# Login attempts, privilege use, exposed services and patch state.
mod_security() {
  local L="$SC_RUN_DIR/80-security.log"
  local since="${SC_SINCE:-24 hours ago}"

  sc_sh "$L" "failed SSH auth" \
    "journalctl -u ssh -u sshd --since '$since' --no-pager 2>/dev/null | grep -iE 'failed password|invalid user|authentication failure|maximum authentication' || echo none"
  sc_sh "$L" "failed auth by source IP" \
    "journalctl -u ssh -u sshd --since '$since' --no-pager 2>/dev/null | grep -oE 'from ([0-9]{1,3}\\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -15 || echo none"
  sc_sh "$L" "successful logins" \
    "journalctl -u ssh -u sshd --since '$since' --no-pager 2>/dev/null | grep -iE 'accepted (password|publickey)' || echo none"
  sc_sh "$L" "current sessions" 'who -a 2>/dev/null; echo; last -x --time-format iso 2>/dev/null | head -12'
  sc_sh "$L" "sudo usage" \
    "journalctl --since '$since' --no-pager 2>/dev/null | grep -iE 'sudo.*(COMMAND=|authentication failure|incorrect password)' || echo none"
  sc_sh "$L" "accounts with login shells" \
    'awk -F: "\$3>=1000 && \$7 !~ /(nologin|false)/ {print \$1, \$3, \$7}" /etc/passwd'
  sc_sh "$L" "uid 0 accounts" 'awk -F: "\$3==0{print \$1}" /etc/passwd'
  sc_sh "$L" "sshd effective config" \
    'sshd -T 2>/dev/null | grep -iE "^(permitrootlogin|passwordauthentication|pubkeyauthentication|port|permitemptypasswords|x11forwarding|maxauthtries)" || grep -iE "^(PermitRootLogin|PasswordAuthentication|Port)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null'
  sc_sh "$L" "firewall" 'ufw status verbose 2>/dev/null || iptables -S 2>/dev/null | head -25 || echo "no ufw/iptables access"'
  sc_sh "$L" "ports listening on all interfaces" \
    'ss -tulnp 2>/dev/null | grep -E "0\\.0\\.0\\.0:|\\[::\\]:" | awk "{print \$1, \$5, \$7}" | sort -u'

  local failed_auth
  failed_auth=$(sc_num "$(journalctl -u ssh -u sshd --since "$since" --no-pager 2>/dev/null | grep -icE 'failed password|invalid user')")
  sc_metric "ssh_failed_auth" "$failed_auth"
  if   [ "${failed_auth:-0}" -ge 500 ]; then sc_finding major security "$failed_auth failed SSH auth attempts in the last day - this machine is being actively brute-forced"
  elif [ "${failed_auth:-0}" -ge 50 ];  then sc_finding minor security "$failed_auth failed SSH auth attempts in the last day - routine internet background noise, but worth knowing"
  fi

  if sshd -T 2>/dev/null | grep -qi '^permitrootlogin yes'; then
    sc_finding major security "SSH permits direct root login"
  fi

  # --- patch state ------------------------------------------------------
  local P="$SC_RUN_DIR/81-updates.log"
  local upd=0 sec=0
  if command -v apt >/dev/null; then
    sc_sh "$P" "upgradable packages" \
      'n=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c .); echo "$n packages upgradable; showing first 60:"; apt list --upgradable 2>/dev/null | tail -n +2 | head -60'
    sc_sh "$P" "security updates" 'apt list --upgradable 2>/dev/null | grep -ci security'
    sc_sh "$P" "unattended-upgrades" \
      "systemctl is-enabled unattended-upgrades 2>/dev/null; tail -25 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || echo 'no log readable'"
    upd=$(sc_num "$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c .)")
    sec=$(sc_num "$(apt list --upgradable 2>/dev/null | grep -ci security)")
  elif command -v pacman >/dev/null; then
    # Read-only: compares installed packages with the last sync of the
    # package databases. It never syncs them itself.
    sc_sh "$P" "upgradable packages (as of the last pacman sync)" \
      'n=$(pacman -Qu 2>/dev/null | grep -c .); echo "$n packages upgradable; showing first 60:"; pacman -Qu 2>/dev/null | head -60; echo; echo "last sync: $(stat -c %y /var/lib/pacman/sync/core.db 2>/dev/null | cut -d. -f1)"'
    upd=$(sc_num "$(pacman -Qu 2>/dev/null | grep -c .)")
  fi
  sc_sh "$P" "reboot required" \
    '[ -f /var/run/reboot-required ] && { cat /var/run/reboot-required; echo "--- packages:"; cat /var/run/reboot-required.pkgs 2>/dev/null; } || echo "no reboot-required flag"'
  sc_sh "$P" "kernel: running vs installed" \
    'echo "running : $(uname -r)"; echo "modules for it: $([ -d /usr/lib/modules/$(uname -r) ] && echo present || echo MISSING)"; echo "newest  : $(ls -1 /boot/vmlinuz-[0-9]* 2>/dev/null | sed "s|.*vmlinuz-||" | sort -V | tail -1)"'

  sc_metric "updates_pending" "$upd"
  sc_metric "security_updates" "$sec"
  [ "${sec:-0}" -ge 20 ] && sc_finding major security "$sec pending security updates"
  [ "${sec:-0}" -gt 0 ] && [ "${sec:-0}" -lt 20 ] && sc_finding minor security "$sec pending security updates ($upd updates total)"
  [ -f /var/run/reboot-required ] && sc_finding minor system "A reboot is required to finish applying updates"

  local running newest
  running=$(uname -r)
  newest=$(ls -1 /boot/vmlinuz-[0-9]* 2>/dev/null | sed 's|.*vmlinuz-||' | sort -V | tail -1)
  if [ -n "$newest" ] && [ "$running" != "$newest" ]; then
    sc_finding minor system "Running kernel $running but $newest is installed - a reboot would pick it up"
  elif [ ! -d "/usr/lib/modules/$running" ]; then
    # Rolling distributions replace the kernel in place; its modules go with it.
    sc_finding minor system "The running kernel $running has been upgraded on disk - reboot to load the new one"
  fi

  return 0
}
