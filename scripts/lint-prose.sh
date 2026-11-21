#!/usr/bin/env bash
set -euo pipefail
if (( $# == 0 )); then
  shopt -s nullglob globstar
  set -- README.md docs/**/*.md runbooks/**/*.md
fi
for file in "$@"; do
  if grep -Eni $'\u2014|\b(leverage|robust|seamless|comprehensive|delve|utilize|streamline)\b|it is worth noting|in today.s' "$file"; then
    printf 'Prose violation in %s\n' "$file" >&2
    failed=1
  elif [[ $? -ne 1 ]]; then
    exit 2
  fi
done
exit "${failed:-0}"
