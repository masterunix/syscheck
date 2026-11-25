# syscheck

A daily health check for a Linux machine, reviewed by Claude.

Once a day a root systemd timer sweeps the system into log files (disk SMART data,
temperatures, kernel and journal errors, services, Docker, network, security,
updates) and applies threshold rules. Claude then investigates the results
read-only and writes a report. The verdict lands on your SSH login banner, so
the first thing you see when you log in is whether the machine is healthy.

It was written for aging hardware with a single disk and no redundancy, where
the useful question is not "is anything wrong" but "is anything getting worse".

## What you see at login

```
────────────────────────────────────────────────────────────────────────────
 System Check                 : Completed 5:12 AM, 25 Nov - no faults
 Severity                     : None
 Claude Message               : All clear. SSD at 31C, 0 reallocated sectors,
                                98% life left. Disk 22% full, 0.4 GB/day.
 Note                         : swap the UPS battery before January

 Token Usage Last Night       : 81,204 tokens
 Token Usage This Month       : 1,903,118 tokens  (25 runs, $9.41)
 Full report                  : /var/lib/syscheck/runs/2026-11-25_050002/report.md
────────────────────────────────────────────────────────────────────────────
```

While a run is in progress the banner says so and updates live, and the
`Note` line is whatever you last set with `syscheck note "..."`.

## Install

Any systemd Linux; packages are installed automatically on Debian, Ubuntu
and Arch (including Omarchy). Download a release, check it, install it:

```sh
V=0.2.0
curl -fLO https://github.com/masterunix/syscheck/releases/download/v$V/syscheck-$V.tar.gz
curl -fLO https://github.com/masterunix/syscheck/releases/download/v$V/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf syscheck-$V.tar.gz && cd syscheck-$V
sudo ./install.sh
```

The installer adds `smartmontools`, `lm-sensors`, `sysstat`, `jq`, `bc` and
`curl` if they are missing. It picks the analysis account automatically (the
user who ran `sudo`); pass `--user NAME` to choose another. It never runs as
root.

Then:

```sh
syscheck claude install         # install Claude Code for that account, if missing
syscheck claude login           # log in (works over SSH: open the link it prints)
sudo syscheck describe --edit   # tell Claude what this machine is for
syscheck run                    # first check now, a few minutes
```

Without Claude, syscheck still runs every day on its threshold rules alone and
says so on the banner.

## Settings

```sh
syscheck settings               # interactive menu
syscheck get                    # show every setting
sudo syscheck set schedule 04:30
sudo syscheck set model opus
sudo syscheck set alarm off
```

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `on` | run on a schedule every day |
| `schedule` | `05:00` | time of the daily run (24h) |
| `analysis` | `on` | have Claude review each run (`off` = rules only) |
| `model` | `sonnet` | Claude model: `sonnet`, `opus`, `haiku` or a full model id |
| `effort` | `high` | reasoning effort: `low` to `max` |
| `budget` | `2.00` | spend cap per run in USD, enforced by the Claude CLI |
| `timeout` | `3600` | hard limit on the analysis, in seconds |
| `user` | auto | account that owns the Claude login and the audio session |
| `disk` | auto | disk to check (auto = the disk holding `/`, through LVM or LUKS) |
| `services` | default | services whose journal errors are read every run |
| `alarm` | `on` | sound an alarm when a fault looks imminent |
| `alarm-seconds` | `600` | how long the alarm sounds |
| `motd` | `on` | show the result on the SSH login banner |
| `keep-runs` | `45` | runs kept on disk |
| `lookback-days` | `7` | furthest back the journal scan reaches |
| `repo` | `masterunix/syscheck` | where `syscheck upgrade` gets releases |

Settings are saved in `/etc/syscheck/syscheck.conf`. Changes take effect
straight away: the timer, sudoers grant and banner hook are regenerated.

### A note to yourself

```sh
sudo syscheck note "swap the UPS battery before January"
syscheck note                   # show it
sudo syscheck note --clear
```

The note shows on the login banner and in `syscheck` status until you clear
it. It is one line, up to 300 characters.

### What Claude is told about the machine

`/etc/syscheck/machine.md` is written at install time from the machine's own
hardware (model, CPU, RAM, disks, running services). Add what the machine is
for and what matters most; Claude reads it at the top of every analysis.
`sudo syscheck describe --regenerate` rebuilds it after a hardware change.

## Claude

```sh
syscheck claude                 # installed? logged in? which plan?
syscheck claude install         # install or update Claude Code (official installer)
syscheck claude login           # log in
syscheck claude logout
syscheck claude test            # one-line prompt to prove it works (capped at $0.10)
```

These run as the analysis account, which is where the login is stored. If the
login expires, the banner says so instead of silently falling back.

## Upgrading

```sh
syscheck version --check        # is there a newer release?
sudo syscheck upgrade           # install the latest release
sudo syscheck upgrade v0.2.0    # install a specific release (also downgrades)
sudo syscheck upgrade --from syscheck-0.2.0.tar.gz   # offline
```

An upgrade downloads the release tarball and its `SHA256SUMS`, refuses to
install on a mismatch, and replaces `/opt/syscheck` as a whole. Settings in
`/etc/syscheck` and history in `/var/lib/syscheck` are kept as they are.

Upgrading from a version before 0.2 (settings inside `/opt/syscheck/etc`):
run the new `install.sh` once; it moves your changed settings to
`/etc/syscheck/syscheck.conf`.

## Uninstalling

```sh
sudo syscheck uninstall          # keeps settings and history
sudo syscheck uninstall --purge  # removes those too
```

## Data stays on each machine

Each installation is self-contained. Nothing one machine collects is sent to
another machine, to GitHub, or into a release.

- **Releases contain only the program.** Settings, the machine description and
  run history are created on the machine at install time and live outside the
  program directory, so neither an install nor an upgrade can carry them
  anywhere. CI rejects commits that contain IP addresses, home directories or
  similar host details.
- **Upgrades only download.** `syscheck upgrade` makes anonymous HTTPS GET
  requests for the release listing and files. It sends nothing about the
  machine.
- **The analysis cannot reach other machines.** Claude is told never to
  contact another host, and the CLI refuses `ssh`, `scp`, `sftp`, `rsync`,
  `curl`, `wget`, `nc`, `socat`, `telnet`, `tailscale` and `git push/clone/fetch`
  outright, along with web fetch and web search. The SSH agent is not passed
  in. This is a strong guardrail rather than a sandbox: the analysis still has
  a shell, so it runs as an ordinary account with read-only privileges.
- **The one thing that does leave:** during analysis, the collected logs are
  sent to Anthropic's API by Claude Code, as with any Claude session. Set
  `analysis off` to keep everything local and rely on the rules alone.

## How a run works

```
systemd timer (root, daily; a run missed while off happens at next boot)
  │
  ├─ 1. collect ........ 11 modules sweep the system into NN-*.log files;
  │                      a SMART short self-test starts first, read at the end
  ├─ 2. rules .......... thresholds -> severity + one-line summary
  │                      the banner is truthful from here on
  ├─ 3. Claude ......... reads the logs, investigates what is unresolved,
  │                      writes report.md and verdict.json (hard timeout)
  └─ 4. finalize ....... Claude's verdict where sane, the rules' otherwise;
                         banner updated, old runs pruned
```

Both the rules and Claude can raise the alarm. Neither can lower the other.

## What gets checked

| Module | Looks at |
|---|---|
| `10-hardware` | board, BIOS, DIMMs, CPU, microcode, thermal zones, fans, throttling, ECC/MCE |
| `20-storage` | SMART attributes and logs, nightly self-test, ext4 state, df/inodes, iostat, D-state processes |
| `30-memory` | memory and swap use, top consumers, OOM kills, pressure stalls |
| `40-logs` | kernel and journal since the previous run: SATA, I/O and ext4 errors, oopses, segfaults, unclean shutdowns |
| `50-services` | failed units, restart loops, timers, boot time, per-service errors |
| `60-docker` | container state and health, restart loops, disk used, container errors |
| `70-network` | link speed, interface errors, gateway/internet/DNS reachability, NTP |
| `80-security` | failed SSH logins, sudo use, sshd config, firewall, open ports, pending updates, reboot needed |
| `90-apps` | nginx, PostgreSQL, Plex, Ollama when present; disk hogs, zombies, load |
| `95-audio` | that the alarm can still make a sound, checked silently |
| `99-trend` | every metric against the previous run, and days until the disk is full |

The trend module matters most. Four reallocated sectors is a worn drive; four
more since yesterday is a drive that will not last the week.

## Logs: capped views and full archives

Claude reads capped views (`NN-*.log`): a probe with more than 120 lines keeps
its first 40 and last 60, with a marker naming the full archive. The complete
output of every probe is kept gzipped in `full/` and read only when needed:

```sh
syscheck full                   # list the archives
syscheck full 41-journal        # read one
syscheck grep "ata[0-9]"        # search all of them
```

So nothing is lost at collection time, and the analysis costs the same on day
1,000 as on day one.

## The alarm

When a fault means the machine may not survive the day, or data loss is
happening, an alarm loops through the speakers (default ten minutes), with a
`wall` message and a desktop notification. It fires on a failed SMART
self-test or health check, new pending or uncorrectable sectors, a read-only
root filesystem, ext4 corruption, uncorrectable ECC errors, a CPU at shutdown
temperature, spin-retry errors, or PostgreSQL corruption.

```sh
syscheck alarm test             # prove it still works
syscheck alarm stop             # silence it
sudo syscheck set alarm off     # never sound it
```

## Safety

- **Claude never changes the system.** It runs as an ordinary account with
  `--permission-mode dontAsk`, a fixed tool list, and the network tools above
  refused. It can write only its two output files.
- **Privileged reads go through one root-owned wrapper.** `priv-read.sh`
  accepts a fixed list of read-only subcommands; that and `run.sh` are the
  whole sudo grant. The wrapper refuses `journalctl` flags that write files or
  read other journals, never starts a pager, and resolves symlinks before
  reading anything under `/var/log`.
- **Root never writes where the analysis account can.** State is root-owned;
  each run's directory is lent to the analysis account during the analysis and
  taken back, with any symlinks removed, before root writes to it again.
- **The banner cannot be used against you.** Control characters are stripped
  from anything Claude writes before it reaches a terminal.
- **The banner never lies.** The rules produce a verdict before Claude runs, so
  a timeout or crash still leaves the real state on screen.
- **Runs cannot pile up**, and every probe and module has its own timeout.

## Commands

```
syscheck                  status (the banner block)
syscheck run              run everything now
syscheck collect          run without Claude
syscheck report           read the latest report
syscheck findings         threshold findings from the last run
syscheck trend            last run against the one before
syscheck history          rolling history
syscheck metrics          every numeric reading
syscheck settings         settings menu
syscheck get / set        read or change one setting
syscheck note "..."       your own line on the banner
syscheck describe         what Claude is told about the machine
syscheck claude ...       install, login, logout, test
syscheck upgrade          install the latest release
syscheck help             everything else
```

## Files

```
/opt/syscheck/                 the program (root-owned, replaced on upgrade)
  etc/syscheck.conf            shipped defaults, do not edit
/etc/syscheck/
  syscheck.conf                this machine's settings
  machine.md                   what Claude is told about this machine
  note                         your banner note
/var/lib/syscheck/
  state.json, motd             current status and rendered banner
  history.tsv, usage.tsv       long-term metrics and token/cost ledger
  runs/YYYY-MM-DD_HHMMSS/      per-run logs, report.md, verdict.json
/etc/systemd/system/syscheck.{timer,service}   generated from the schedule
/etc/sudoers.d/99-syscheck     generated for the analysis account
/etc/update-motd.d/99-syscheck login banner (or /etc/profile.d/syscheck-banner.sh)
/var/log/syscheck.log
```

## Cost

On `sonnet`, a typical run costs roughly 20 to 50 US cents. `opus` reasons
better about strange hardware symptoms at several times the price. `budget`
caps every run.

## Releasing

Bump `VERSION`, commit, then tag and push:

```sh
git tag v$(cat VERSION) && git push origin main --tags
```

The release workflow checks that the tag matches `VERSION`, runs the checks,
builds `syscheck-X.Y.Z.tar.gz` with `git archive`, and publishes it with
`SHA256SUMS`.

## License

MIT
