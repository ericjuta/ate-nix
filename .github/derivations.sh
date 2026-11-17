#!/usr/bin/env bash
# Prints every derivation that CI builds, one per line, for both systems:
# the flake checks, the reference project's checks and the private-cache proof
# images. Evaluation only, nothing is built. To test whether a file is inert
# (see ci-scope.sh), run this, change the file, run it again and diff.
set -euo pipefail

cd "$(dirname "$0")/.."
names='c: builtins.concatStringsSep " " (builtins.attrNames c)'

{
  for system in x86_64-linux aarch64-linux; do
    for dir in . examples/reference; do
      label=$([ "$dir" = . ] && echo root || echo reference)
      for name in $(cd "$dir" && nix eval --raw ".#checks.$system" --apply "$names"); do
        echo "$label.$system.$name $(cd "$dir" && nix eval --raw ".#checks.$system.$name.drvPath")"
      done
    done
  done
  for image in signed unsigned rogue; do
    echo "private.$image $(nix eval --impure --raw --file kind/private-images.nix "$image.drvPath" --argstr nonce ci)"
  done
} | sort
