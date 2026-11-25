#!/usr/bin/env bash
# Upgrade syscheck from a GitHub release.
#
#   upgrade.sh                  install the latest release if it is newer
#   upgrade.sh --check          only report whether a newer release exists
#   upgrade.sh v0.3.0           install that exact release (also downgrades)
#   upgrade.sh --from FILE      install from a release tarball already on disk
#   upgrade.sh --force          reinstall even when already up to date
#
# What leaves this machine: anonymous HTTPS GET requests for the release
# listing and the release files. Nothing about the machine is sent. Settings
# (/etc/syscheck) and history (/var/lib/syscheck) are kept as they are.
set -euo pipefail
SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

REPO="${SC_REPO:-masterunix/syscheck}"
API="https://api.github.com/repos/$REPO/releases"
UA="syscheck-updater"
CHECK=0; FORCE=0; WANT=""; FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check|-c) CHECK=1 ;;
    --force|-f) FORCE=1 ;;
    --from)     FROM="${2:-}"; shift ;;
    v[0-9]*|[0-9]*) WANT="v${1#v}" ;;
    -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }  # is $1 > $2
fetch() { curl -fsSL --proto '=https' --tlsv1.2 -A "$UA" --retry 2 --max-time 120 "$@"; }

CURRENT="$SC_VERSION"

if [ -z "$FROM" ]; then
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
  command -v jq   >/dev/null || { echo "jq is required" >&2; exit 1; }
  if [ -n "$WANT" ]; then
    TAG="$WANT"
  else
    TAG="$(fetch "$API/latest" | jq -r '.tag_name // empty')" || true
    [ -n "${TAG:-}" ] || { echo "could not read the latest release of $REPO" >&2; exit 1; }
  fi
  LATEST="${TAG#v}"

  if [ "$CHECK" = "1" ]; then
    if newer "$LATEST" "$CURRENT"; then
      echo "syscheck $LATEST is available (installed: $CURRENT). Upgrade with: sudo syscheck upgrade"
    else
      echo "syscheck $CURRENT is up to date (latest release: $LATEST)"
    fi
    exit 0
  fi

  if [ -z "$WANT" ] && [ "$FORCE" = "0" ] && ! newer "$LATEST" "$CURRENT"; then
    echo "syscheck $CURRENT is up to date (latest release: $LATEST)"; exit 0
  fi
fi

[ "$(id -u)" = "0" ] || { echo "run as root: sudo syscheck upgrade" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/syscheck-upgrade.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "no such file: $FROM" >&2; exit 1; }
  cp "$FROM" "$WORK/release.tar.gz"
  say "installing from $FROM (no checksum file to compare against)"
else
  NAME="syscheck-$LATEST.tar.gz"
  BASE="https://github.com/$REPO/releases/download/$TAG"
  say "downloading syscheck $LATEST"
  fetch -o "$WORK/$NAME" "$BASE/$NAME"
  fetch -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS"
  say "verifying the checksum"
  grep -E "  $NAME\$" "$WORK/SHA256SUMS" > "$WORK/expected" || { echo "$NAME is not listed in SHA256SUMS" >&2; exit 1; }
  ( cd "$WORK" && sha256sum -c --quiet expected ) || { echo "checksum mismatch: refusing to install" >&2; exit 1; }
  mv "$WORK/$NAME" "$WORK/release.tar.gz"
fi

mkdir "$WORK/src"
tar -xzf "$WORK/release.tar.gz" -C "$WORK/src" --no-same-owner --no-same-permissions
SRC="$(find "$WORK/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$SRC" ] && [ -f "$SRC/install.sh" ] && [ -f "$SRC/VERSION" ] || { echo "the release archive does not look like syscheck" >&2; exit 1; }

say "installing syscheck $(cat "$SRC/VERSION") over $CURRENT"
bash "$SRC/install.sh" --upgrade
