#!/usr/bin/env bash
set -euo pipefail
if (( $# == 0 )); then
  shopt -s nullglob globstar
  set -- README.md docs/**/*.md
fi
(( $# )) || exit 0
awk '
  function has_number(body) { gsub(/p95/, "", body); return body ~ /[0-9]/ }
  BEGIN { RS = "" }
  {
    block = tolower($0)
    keyword = "(^|[^a-z])(mttr|p95|median|dropped|ram)([^a-z]|$)"
    if (block ~ keyword && has_number(block) &&
        block !~ /\][(][^ )]*results\// && block !~ /<!-- target -->/) {
      printf "%s paragraph %d lacks a results link or target marker\n", FILENAME, FNR
      failed = 1
    }
  }
  END { exit failed }
' "$@"
