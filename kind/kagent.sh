#!/usr/bin/env bash
# Turns a stock kagent install on the kind cluster of kind/README.md into one
# that runs Nix images: loads the four images that the flake builds, switches
# kagent's Substrate (atelet, ateapi) and its controller to them, and lets the
# three kagent CRDs accept `nix:/nix/store/...` references.
# docs/kagent.md has the steps before and after this script.
#
# Needs: OUT (directory with the four *.tar.gz of `nix build`), SUBSTRATE (a
# checkout of kagent-dev/substrate, for its hack/kind.sh), kubectl, jq, docker.
set -euo pipefail

: "${OUT:?directory with the image tarballs}" "${SUBSTRATE:?kagent-dev/substrate checkout}"
CLUSTER=${KIND_CLUSTER_NAME:-ate-nix}
KAGENT_VERSION=${KAGENT_VERSION:-1.0.1}
SUBSTRATE_VERSION=${SUBSTRATE_VERSION:-1.0.0}
here=$(cd "$(dirname "$0")" && pwd)

k() { kubectl --context "kind-$CLUSTER" "$@"; }

echo "== images"
for image in kagent-atelet kagent-ateapi kagent-controller; do
  archive=$(find "$OUT" -maxdepth 1 -name "*-$image.tar.gz" | head -n 1)
  [ -n "$archive" ] || { echo "no *-$image.tar.gz in $OUT" >&2; exit 1; }
  (cd "$SUBSTRATE" && hack/kind.sh load image-archive "$archive" --name "$CLUSTER")
done

echo "== node"
docker exec -i "$CLUSTER-control-plane" sh <"$here/node-setup.sh"

echo "== substrate"
k -n ate-system patch ds atelet --type=json --patch-file "$here/atelet-nix.patch.json"
k -n ate-system set image ds/atelet "atelet=docker.io/ate-nix/kagent-atelet:$SUBSTRATE_VERSION"
k -n ate-system set image deploy/ate-api-server "ate-api-server=docker.io/ate-nix/kagent-ateapi:$SUBSTRATE_VERSION"
k -n ate-system rollout status ds/atelet --timeout=5m
k -n ate-system rollout status deploy/ate-api-server --timeout=5m

echo "== kagent"
# The patterns of patches/kagent, put into the installed CRDs. The Agent one
# is on a status field: without it the Agent boots, and its status update is
# refused on every reconcile.
old='^[^[:space:]@]+@sha256:[a-f0-9]{64}$'
new='^([^[:space:]@]+@sha256:[a-f0-9]{64}|nix:/nix/store/[0-9a-z]{32}-[^[:space:]/]+)$'
for crd in harnesses sandboxtemplates agents; do
  k get crd "$crd.api.kagent.dev" -o json |
    jq --arg old "$old" --arg new "$new" \
      'walk(if type == "object" and .pattern == $old then .pattern = $new else . end)' |
    k replace -f -
done
k -n kagent set image deploy/kagent-controller "controller=docker.io/ate-nix/kagent-controller:$KAGENT_VERSION"
k -n kagent rollout status deploy/kagent-controller --timeout=5m
echo DONE
