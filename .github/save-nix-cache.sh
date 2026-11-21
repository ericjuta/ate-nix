#!/usr/bin/env bash
# Fills a file binary cache at $1, which CI saves between runs, with every
# store path that this run built itself or took from the previous archive.
# Paths signed by cache.nixos.org are left out: the next run downloads them
# again from there.
#
# Entries of the previous archive stay when a derivation that this run
# evaluated still produces them. A run that takes a finished check from the
# archive never fetches what that check was built from; without this rule
# those inputs would leave the archive, and the next change to the check
# would compile all of them again. Entries that no evaluated derivation
# produces are removed, so the archive holds nothing from old pins.
set -euo pipefail

cache=$1
store=file://$cache
mkdir -p "$cache"

all=$(mktemp)
nix path-info --all --sigs | tr '\t' ' ' >"$all"
grep -v 'cache\.nixos\.org-1:' "$all" | cut -d' ' -f1 | grep -v '\.drv$' >"$all.built" || true
grep 'cache\.nixos\.org-1:' "$all" | cut -d' ' -f1 | cut -d/ -f4 | cut -c1-32 >"$all.upstream" || true

# The hash part of every output of every derivation in the local store.
# Evaluating a check puts its whole build closure there as .drv files.
cut -d' ' -f1 "$all" | grep '\.drv$' | xargs -r nix-store --query --outputs |
  cut -d/ -f4 | cut -c1-32 | sort -u >"$all.wanted" || true

kept=0
for info in "$cache"/*.narinfo; do
  [ -e "$info" ] || continue
  if grep -qxF "$(basename "$info" .narinfo)" "$all.wanted"; then
    kept=$((kept + 1))
  else
    rm -f "$info"
  fi
done
# NAR files are named by content, so two entries can share one: delete a
# file only when no remaining entry names it.
find "$cache" -maxdepth 1 -name '*.narinfo' -exec sed -n 's/^URL: //p' {} + | sort -u >"$all.nars"
find "$cache" -type f -path '*/nar/*' -printf '%P\n' | sort | comm -23 - "$all.nars" |
  while read -r nar; do rm -f "$cache/$nar"; done

# A binary cache accepts a path only when it knows every reference. Borrow
# the descriptions of the upstream paths for the copy, then remove them, so
# the cache holds only what was built here.
stubs=$(mktemp -d)
(cd "$stubs" && xargs -r -P 16 -I{} curl -fsS --retry 3 -o {}.narinfo https://cache.nixos.org/{}.narinfo) <"$all.upstream"
for stub in "$stubs"/*.narinfo; do
  [ -e "$stub" ] || continue
  if [ -e "$cache/$(basename "$stub")" ]; then
    # The archive holds this path already; leave its entry alone.
    rm -f "$stub"
  else
    cp "$stub" "$cache/"
  fi
done

xargs -r nix copy --no-recursive --to "$store?compression=zstd" <"$all.built"

for stub in "$stubs"/*.narinfo; do
  [ -e "$stub" ] || continue
  rm -f "$cache/$(basename "$stub")"
done

echo "built paths: $(wc -l <"$all.built")"
echo "kept from the previous archive: $kept"
echo "archive entries: $(find "$cache" -maxdepth 1 -name '*.narinfo' | wc -l)"
du -sh "$cache"
