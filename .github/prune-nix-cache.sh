#!/usr/bin/env bash
# Deletes this system's Nix cache archives other than the one about to be
# saved. Each archive is about 5 GB and the repository's Actions cache holds
# 10 GB, so a stale archive of one system would push the other system's out.
# Usage: prune-nix-cache.sh SYSTEM KEEP_KEY
set -euo pipefail

system=$1
keep=$2
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/caches?per_page=100&key=nix-cache-$system-" \
  --jq '.actions_caches[] | [.id, .key] | @tsv' |
  while IFS=$'\t' read -r id key; do
    if [ "$key" != "$keep" ]; then
      echo "deleting $key"
      gh api -X DELETE "repos/$GITHUB_REPOSITORY/actions/caches/$id" >/dev/null
    fi
  done
