#!/usr/bin/env bash
# Fail if tracked files contain details that belong to one machine: IP
# addresses, home directories, MAC addresses or email addresses. Releases must
# carry the program only, never anything a particular host produced.
set -uo pipefail
cd "$(dirname "$0")/.."
files=$(git ls-files | grep -vE '^(share/|LICENSE$|tools/check-no-host-data.sh$)')
status=0
hit() { echo "host data? $1"; status=1; }

# IPv4 addresses, apart from well-known public resolvers and loopback/any.
grep -nHoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' $files 2>/dev/null \
  | grep -vE ':(1\.1\.1\.1|8\.8\.8\.8|127\.0\.0\.1|0\.0\.0\.0)$' \
  | while read -r l; do echo "host data? IP address: $l"; done | grep . && status=1

# Concrete home directories (variables such as $HOME or /home/$USER are fine).
grep -nHE '/home/[a-z][a-z0-9_-]+' $files 2>/dev/null | grep -vE '/home/\$' && { echo "host data? home directory above"; status=1; }

# MAC addresses.
grep -nHiE '\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b' $files 2>/dev/null && { echo "host data? MAC address above"; status=1; }

# Email addresses, apart from the GitHub noreply form and placeholders.
grep -nHoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' $files 2>/dev/null \
  | grep -vE 'noreply|@example\.' && { echo "host data? email address above"; status=1; }

[ "$status" = "0" ] && echo "no host data found in $(echo "$files" | wc -l | tr -d ' ') tracked files"
exit "$status"
