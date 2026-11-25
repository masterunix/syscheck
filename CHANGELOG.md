# Changelog

## 0.2.1

- **One-line install and upgrade**: `curl -fsSL .../releases/latest/download/get.sh | sudo bash`
  sets up a new machine or upgrades any existing install, 0.1 included. It
  verifies the release checksum and leaves nothing behind on the machine.
- **Several machines**: `tools/fleet.sh` shows every machine's version and
  last result, upgrades the ones behind, and starts checks, over SSH from one
  workstation. The list of machines stays in `~/.config/syscheck/hosts` there.
- The PostgreSQL data size is read from the server's own `data_directory`
  instead of a path that assumed version 16.
- **Fix: `syscheck run` from a terminal hung forever at the Claude stage,
  and Ctrl-C could not stop it.** The Claude CLI inherited the terminal as
  stdin while `timeout` ran it in a background process group, so the kernel
  stopped it on its first touch of the terminal, and stopped the `timeout`
  meant to kill it along with it. Runs now give every command `/dev/null` as
  stdin. Scheduled runs, which have no terminal, were not affected.
- **Ctrl-C works**, as do `systemctl stop` and a dropped SSH session: the run
  stops everything it started and the banner says "Stopped" instead of being
  left on "Claude is reviewing".
- The alarm and the analysis no longer inherit the run lock, which kept a new
  run from starting while an alarm was still sounding.
- A login check that does not answer is reported as such, not as "not logged in".

## 0.2.0

First public release. syscheck now installs on any Ubuntu or Debian machine
instead of the one it was written for.

- **Settings**: `syscheck settings` menu, `syscheck get` and `syscheck set`
  for schedule, model, effort, budget, analysis on/off, alarm, banner, disk,
  account, watched services and retention. Saved per machine in
  `/etc/syscheck/syscheck.conf`; changes apply immediately.
- **Note line**: `syscheck note "text"` puts your own line on the login banner.
- **Claude**: `syscheck claude install|login|logout|test|status`, and the
  banner says when Claude is missing or logged out.
- **Upgrades**: `syscheck upgrade` installs the latest GitHub release after
  checking its SHA-256 checksum; `--check`, a specific version, or `--from` a
  local archive. Settings and history are kept.
- **Scheduling**: a systemd timer replaces cron, so a run missed while the
  machine was off or asleep happens at the next boot.
- **More distributions**: Arch (and Omarchy) as well as Debian and Ubuntu:
  pacman packages and update checks, a profile.d banner where update-motd.d
  is missing, btrfs roots (subvolumes, LUKS) with btrfs error counters, and
  Claude Code installed through mise.
- **Uninstall**: `syscheck uninstall`, with `--purge` to remove data too.
- **Per-machine description**: `/etc/syscheck/machine.md` is generated from
  the machine's own hardware and edited by the owner; nothing about any one
  machine ships in the program.
- **Detection**: the analysis account, disk (through LVM or LUKS), root
  partition and PostgreSQL unit are detected instead of hardcoded.
- **Data boundaries**: the analysis refuses ssh, scp, rsync, curl, wget, nc
  and similar tools and is told never to contact another machine. CI rejects
  host details in the repository.
- **Security fixes**: the state directory is root-only for writing, and each
  run directory is taken back from the analysis account before root writes to
  it (a planted symlink could previously redirect root's writes). The
  diagnostics wrapper refuses `journalctl --cursor-file` (which writes to any
  path as root) and other file/image flags, never starts a pager, and resolves
  symlinks before reading `/var/log`. Control characters are stripped from
  Claude's banner message.
- **Fixes**: per-host settings were overridden by a second read of the
  defaults; the clean-shutdown check counted the boot list's header as a boot,
  missed shutdowns whose journal ended early, and treated hibernation as a
  crash; failed units were listed by their bullet; Docker is no longer
  started by its own health check when it is socket-activated; every run-log line was written twice; `sensors-detect` now runs
  only with `--detect-sensors`.

## 0.1.0

Initial version, written for one specific machine.
