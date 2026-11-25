# syscheck: show the latest result on interactive SSH logins, for systems
# without update-motd.d. Installed to /etc/profile.d by syscheck.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if [ -n "${SSH_CONNECTION:-}" ] && [ -r /var/lib/syscheck/motd ]; then
  cat /var/lib/syscheck/motd
fi
