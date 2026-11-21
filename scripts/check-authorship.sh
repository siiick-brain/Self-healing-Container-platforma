#!/usr/bin/env bash
set -euo pipefail
: "${OWNER_EMAIL:?Set the OWNER_EMAIL repository variable}"
range=${1:?Pass a commit range}
git rev-list "$range" >/dev/null
owner_noreply='^([0-9]+[+])?siiick-brain@users[.]noreply[.]github[.]com$'
while read -r commit; do
  author=$(git show -s --format=%ae "$commit")
  committer=$(git show -s --format=%ce "$commit")
  if [[ $author != "$OWNER_EMAIL" && ! $author =~ $owner_noreply ]]; then
    echo "Unexpected author on $commit" >&2
    exit 1
  fi
  if [[ $committer != "$OWNER_EMAIL" && ! $committer =~ $owner_noreply ]]; then
    if [[ $committer != web-flow@users.noreply.github.com || ! $author =~ $owner_noreply ]]; then
      echo "Unexpected committer on $commit" >&2
      exit 1
    fi
  fi
  if git show -s --format=%B "$commit" | grep -Ei '^[[:space:]]*co-authored-by[[:space:]]*:'; then
    echo "Co-author trailer on $commit" >&2
    exit 1
  fi
done < <(git rev-list "$range")
