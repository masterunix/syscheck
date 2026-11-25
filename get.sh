#!/usr/bin/env bash
# Install or upgrade syscheck from a GitHub release, in one line:
#
#   curl -fsSL https://github.com/masterunix/syscheck/releases/latest/download/get.sh | sudo bash
#
# The same line sets up a new machine and upgrades an existing one, whatever
# version it has. Options go after `bash -s --`:
#
#   --version X.Y.Z    that release instead of the latest (also downgrades)
#   --user NAME        and any other install.sh option, passed through
#
# It downloads the release tarball and SHA256SUMS, refuses to install on a
# mismatch, runs the release's own install.sh, and leaves nothing behind.
# Nothing about the machine is sent anywhere.

# Everything is inside main(), so bash has read the whole script before any of
# it runs: under `curl | bash`, a command that read stdin would otherwise eat
# the rest of the script.
SYSCHECK_GET_WORK=""
main() {
  set -euo pipefail
  local repo="masterunix/syscheck" want="" base name src
  local -a pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) want="${2:-}"; want="${want#v}"; shift ;;
      --repo)    repo="${2:-}"; shift ;;
      -h|--help) echo "usage: curl -fsSL <url>/get.sh | sudo bash -s -- [--version X.Y.Z] [install.sh options]"; return 0 ;;
      *)         pass+=("$1") ;;
    esac
    shift
  done

  [ "$(id -u)" = "0" ] || { echo "syscheck: run this as root: curl -fsSL <url>/get.sh | sudo bash" >&2; return 1; }
  local c
  for c in curl tar sha256sum; do
    command -v "$c" >/dev/null || { echo "syscheck: '$c' is required" >&2; return 1; }
  done

  if [ -n "$want" ]; then base="https://github.com/$repo/releases/download/v$want"
  else                    base="https://github.com/$repo/releases/latest/download"; fi
  fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 300 -A syscheck-get "$@"; }

  SYSCHECK_GET_WORK="$(mktemp -d /var/tmp/syscheck-get.XXXXXX)"
  trap 'rm -rf "$SYSCHECK_GET_WORK"' EXIT
  local w="$SYSCHECK_GET_WORK"

  # SHA256SUMS names the tarball, so the version comes from the release itself.
  fetch -o "$w/SHA256SUMS" "$base/SHA256SUMS" \
    || { echo "syscheck: could not download $base/SHA256SUMS" >&2; return 1; }
  name="$(grep -oE 'syscheck-[0-9][0-9A-Za-z.+-]*\.tar\.gz' "$w/SHA256SUMS" | head -1)"
  [ -n "$name" ] || { echo "syscheck: no release tarball listed in SHA256SUMS" >&2; return 1; }
  echo "==> downloading $name"
  fetch -o "$w/$name" "$base/$name"
  ( cd "$w" && grep -E "  $name\$" SHA256SUMS | sha256sum -c --quiet - ) \
    || { echo "syscheck: checksum mismatch for $name: refusing to install" >&2; return 1; }
  echo "==> checksum verified"

  tar -xzf "$w/$name" -C "$w" --no-same-owner --no-same-permissions
  src="$w/${name%.tar.gz}"
  [ -f "$src/install.sh" ] && [ -f "$src/VERSION" ] \
    || { echo "syscheck: $name does not look like a syscheck release" >&2; return 1; }

  # An existing install of any version is upgraded in place; settings and
  # history are kept.
  [ -d /opt/syscheck ] && pass=(--upgrade ${pass[@]+"${pass[@]}"})
  bash "$src/install.sh" ${pass[@]+"${pass[@]}"} </dev/null
}
main "$@"
