#!/usr/bin/env bash
set -euo pipefail

physical="$(find src -type f -name '*.sol' -print0 | xargs -0 cat | wc -l | tr -d ' ')"
non_empty="$(find src -type f -name '*.sol' -print0 | xargs -0 awk 'NF { count++ } END { print count+0 }')"

echo "src physical LOC: ${physical}"
echo "src non-empty LOC: ${non_empty}"

if (( physical < 3000 || physical > 4000 )); then
  echo "src physical LOC must remain between 3000 and 4000" >&2
  exit 1
fi

if (( non_empty < 3000 || non_empty > 4000 )); then
  echo "src non-empty LOC must remain between 3000 and 4000" >&2
  exit 1
fi
