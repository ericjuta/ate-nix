#!/usr/bin/env bash
# Copies every store path that this machine built itself into a file binary
# cache at $1, which CI saves between runs. Paths signed by cache.nixos.org
# are left out: the next run downloads them again from there.
set -euo pipefail

cache=$1
store=file://$cache
mkdir -p "$cache"

# Start again when the cache holds too much from old pins.
if [ "$(du -s --block-size=1M "$cache" | cut -f1)" -gt 4000 ]; then
  rm -rf "$cache"
  mkdir -p "$cache"
fi

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
  name=$(basename "$stub")
  if [ -e "$cache/$name" ]; then rm "$stub"; else cp "$stub" "$cache/$name"; fi
done

xargs -r nix copy --no-recursive --to "$store?compression=zstd" <"$all.built"

for stub in "$stubs"/*.narinfo; do
  [ -e "$stub" ] || continue
  rm -f "$cache/$(basename "$stub")"
done

echo "built paths: $(wc -l <"$all.built")"
du -sh "$cache"
