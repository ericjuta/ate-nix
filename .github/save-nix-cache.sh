#!/usr/bin/env bash
# Fills a file binary cache at $1, which CI saves between runs, with every
# store path that this run built itself or took from the previous archive.
# Paths signed by cache.nixos.org are left out: the next run downloads them
# again from there. The archive starts empty each time, so it holds nothing
# from old pins.
set -euo pipefail

cache=$1
store=file://$cache
rm -rf "$cache"
mkdir -p "$cache"

all=$(mktemp)
nix path-info --all --sigs | tr '\t' ' ' >"$all"
grep -v 'cache\.nixos\.org-1:' "$all" | cut -d' ' -f1 | grep -v '\.drv$' >"$all.built" || true
grep 'cache\.nixos\.org-1:' "$all" | cut -d' ' -f1 | cut -d/ -f4 | cut -c1-32 >"$all.upstream" || true

# A binary cache accepts a path only when it knows every reference. Borrow
# the descriptions of the upstream paths for the copy, then remove them, so
# the cache holds only what was built here.
stubs=$(mktemp -d)
(cd "$stubs" && xargs -r -P 16 -I{} curl -fsS --retry 3 -o {}.narinfo https://cache.nixos.org/{}.narinfo) <"$all.upstream"
for stub in "$stubs"/*.narinfo; do
  [ -e "$stub" ] || continue
  cp "$stub" "$cache/"
done

xargs -r nix copy --no-recursive --to "$store?compression=zstd" <"$all.built"

for stub in "$stubs"/*.narinfo; do
  [ -e "$stub" ] || continue
  rm -f "$cache/$(basename "$stub")"
done

echo "built paths: $(wc -l <"$all.built")"
du -sh "$cache"
