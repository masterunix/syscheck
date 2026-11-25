#!/usr/bin/env bash
# Turn findings.tsv into a single severity + one-line summary.
# This is the deterministic safety net: if Claude never runs, or hangs, or
# returns nonsense, the MOTD still tells the truth about the box.
set -uo pipefail
SC_PREFIX="${SC_PREFIX:-/opt/syscheck}"
. "$SC_PREFIX/lib/common.sh"

F="$SC_RUN_DIR/findings.tsv"
[ -f "$F" ] || { echo -e "none\t0\tAll checks passed."; exit 0; }

crit=$(awk -F'\t' '$1=="critical"' "$F" | wc -l | tr -d " ")
majr=$(awk -F'\t' '$1=="major"'    "$F" | wc -l | tr -d " ")
minr=$(awk -F'\t' '$1=="minor"'    "$F" | wc -l | tr -d " ")
imminent=$(awk -F'\t' '$4=="1"' "$F" | wc -l | tr -d " ")

if   [ "$crit" -gt 0 ]; then sev="critical"
elif [ "$majr" -gt 0 ]; then sev="major"
elif [ "$minr" -gt 0 ]; then sev="minor"
else                         sev="none"
fi

# Lead with the single worst finding -- that is what someone logging in needs.
top=$(awk -F'\t' '$1=="critical"{print $3; exit}' "$F")
[ -z "$top" ] && top=$(awk -F'\t' '$1=="major"{print $3; exit}' "$F")
[ -z "$top" ] && top=$(awk -F'\t' '$1=="minor"{print $3; exit}' "$F")
[ -z "$top" ] && top="All checks passed."

summary="$top"
extra=$(( crit + majr + minr - 1 ))
[ "$extra" -gt 0 ] && summary="$top (+$extra more)"

printf '%s\t%s\t%s\n' "$sev" "$imminent" "$summary"
