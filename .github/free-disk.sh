#!/usr/bin/env bash
# Removes the toolchains that a hosted runner ships and these jobs do not use,
# so the Nix store has room for the closure bundle. Deleting one directory
# tree is slow on the runner's disk, so the two levels below each root go in
# parallel; the step took 74 to 315 s when it ran one rm after another.
set -euo pipefail

df -h /
start=$SECONDS

targets=(
  /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup
  /opt/hostedtoolcache /usr/share/swift /usr/local/share/powershell
  /usr/local/share/chromium /usr/lib/jvm /usr/lib/google-cloud-sdk /opt/az
  /opt/microsoft /opt/google /usr/share/miniconda /usr/local/julia*
  /usr/local/lib/node_modules /usr/lib/llvm-* /usr/lib/firefox
  /home/runner/.rustup /home/runner/.cargo /opt/pipx
)
present=()
for target in "${targets[@]}"; do
  # A glob that matches nothing stays literal and is skipped here.
  [ -e "$target" ] && present+=("$target")
done

# Image removal runs beside the file removal; they use different storage paths.
sudo docker image prune --all --force >/dev/null &
prune=$!

sudo find "${present[@]}" -mindepth 2 -maxdepth 2 -print0 | sudo xargs -0 -r -P 32 rm -rf
echo "two levels removed after $((SECONDS - start)) s"
sudo rm -rf "${present[@]}"
echo "trees removed after $((SECONDS - start)) s"
wait "$prune"
echo "images removed after $((SECONDS - start)) s"

df -h /
