#!/usr/bin/env bash
# End-to-end test on a throwaway machine with passwordless sudo (CI runner):
# install, change settings, run a rules-only check, upgrade, uninstall.
set -euxo pipefail
cd "$(dirname "$0")/.."
me="$(id -un)"

sudo ./install.sh || echo "install reported failed checks (expected on a VM without SMART)"

test -x /opt/syscheck/bin/syscheck
test "$(cat /opt/syscheck/VERSION)" = "$(cat VERSION)"
grep -q "^SC_USER=$me\$" /etc/syscheck/syscheck.conf
test -s /etc/syscheck/machine.md
grep -qE '^0 5 \* \* \* +root +/opt/syscheck/bin/run.sh' /etc/cron.d/syscheck
sudo visudo -cf /etc/sudoers.d/99-syscheck
test "$(stat -c %U:%a /var/lib/syscheck)" = "root:755"
syscheck version
syscheck get

# settings
sudo syscheck set schedule 4:30
grep -qE '^30 4 \* \* \*' /etc/cron.d/syscheck
sudo syscheck set analysis off
sudo syscheck set model haiku
test "$(syscheck get model)" = haiku
if sudo syscheck set schedule 25:00; then exit 1; fi
if sudo syscheck set user root; then exit 1; fi
if sudo syscheck set nonsense 1; then exit 1; fi
sudo syscheck note "ci note $(printf '\033')[31m"
syscheck note | grep -q "ci note"
if syscheck note | grep -q $'\033'; then exit 1; fi

# a rules-only run through the sudoers grant
syscheck collect
test -s /var/lib/syscheck/latest/metrics.tsv
grep -q '"phase": "complete"' /var/lib/syscheck/state.json
grep -q "ci note" /var/lib/syscheck/motd
test "$(stat -c %U /var/lib/syscheck/latest/)" = root

# the diagnostics wrapper refuses flags that write files as root
if sudo -n /opt/syscheck/bin/priv-read.sh journal --cursor-file=/tmp/sc-pwn -n1; then exit 1; fi
test ! -e /tmp/sc-pwn
ln -sf /etc/shadow /var/log/sc-link
if sudo -n /opt/syscheck/bin/priv-read.sh readlog /var/log/sc-link; then exit 1; fi
sudo rm -f /var/log/sc-link

# upgrade from a local release archive keeps settings and the note
git archive --prefix=syscheck-test/ -o /tmp/sc.tar.gz HEAD
sudo syscheck upgrade --from /tmp/sc.tar.gz
test "$(syscheck get model)" = haiku
syscheck note | grep -q "ci note"
grep -qE '^30 4 ' /etc/cron.d/syscheck

# turning the schedule off removes the cron entry
sudo syscheck set enabled off
test ! -e /etc/cron.d/syscheck

sudo syscheck uninstall --purge </dev/null
test ! -e /opt/syscheck
test ! -e /etc/syscheck
test ! -e /etc/sudoers.d/99-syscheck
test ! -e /usr/local/bin/syscheck
echo "install test passed"
