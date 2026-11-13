#!/usr/bin/env bash
# Proves the supply-chain rule on the kind cluster of kind/README.md: a node
# takes a private image only when a key it trusts signed it.
#
# Builds three images no public cache has, publishes them in a local binary
# cache (one signed with a key the node trusts, one unsigned, one signed with
# a key the node does not trust), removes them from the node's store, and
# creates a template from each. The first must boot; the other two must fail
# and must not reach the node's store.
#
#   WORKER_IMAGE=<ateworker-gvisor image> kind/private-cache.sh
#
# Needs kubectl, kubectl-ate, envsubst and docker on PATH. Run after
# kind/prove.sh's prerequisites are in place.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-ate-nix}"
CONTEXT="kind-${KIND_CLUSTER_NAME}"
NODE="${NODE:-${KIND_CLUSTER_NAME}-control-plane}"
STORE_VOLUME="${STORE_VOLUME:-ate-nix-store}"
CACHE="${CACHE:-ate-nix-cache}" # Docker volume and container name
: "${WORKER_IMAGE:?set WORKER_IMAGE to an ateworker-gvisor image reference}"
export WORKER_IMAGE

k() { kubectl --context "${CONTEXT}" "$@"; }
ate() { kubectl ate --context "${CONTEXT}" "$@" 2> >(grep -v 'no --token-file given' >&2); }
node() { docker exec "${NODE}" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

run="$(date +%s)"
cleanup() {
  for tag in signed unsigned rogue; do
    ate delete actor-template "private-${tag}-${run}" -a ate-nix-proof >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

echo "== build, publish, remove from the node's store"
# One container: the secret keys never leave it. The builder shares the node's
# store (see kind/README.md), so the images are deleted from it afterwards and
# the cache is the only place left to get them from.
docker run --rm -i -e NONCE="${run}" \
  -v "${STORE_VOLUME}:/nix" -v "${CACHE}:/cache" -v "${HERE}/..:/src:ro" \
  nixos/nix:latest sh -eu <<'EOF'
git config --global --add safe.directory /src
export NIX_CONFIG="experimental-features = nix-command flakes"
nix key generate-secret --key-name ate-proof-1 > /tmp/trusted.sec
nix key generate-secret --key-name ate-rogue-1 > /tmp/rogue.sec
nix key convert-secret-to-public < /tmp/trusted.sec > /cache/trusted.pub
: > /cache/paths
for tag in signed unsigned rogue; do
  path="$(nix build --impure --no-link --print-out-paths \
    --file /src/kind/private-images.nix --argstr nonce "${NONCE}" "${tag}")"
  case "${tag}" in
    signed) to="file:///cache?secret-key=/tmp/trusted.sec" ;;
    unsigned) to="file:///cache" ;;
    rogue) to="file:///cache?secret-key=/tmp/rogue.sec" ;;
  esac
  nix copy --to "${to}" "${path}"
  nix-store --delete $(nix-store --query --requisites "${path}" | grep -- -ate-private-) >/dev/null
  echo "${tag}=${path}" >> /cache/paths
done
EOF

echo "== cache"
docker container inspect "${CACHE}" >/dev/null 2>&1 ||
  docker run -d --name "${CACHE}" --network kind -v "${CACHE}:/srv:ro" \
    busybox httpd -f -p 80 -h /srv >/dev/null
paths="$(docker exec "${CACHE}" cat /srv/paths)"
public_key="$(docker exec "${CACHE}" cat /srv/trusted.pub)"
path_of() { sed -n "s/^$1=//p" <<<"${paths}"; }

echo "== node trusts ${public_key%%:*}"
docker exec -i "${NODE}" env \
  SUBSTITUTERS="https://cache.nixos.org http://${CACHE}" \
  TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${public_key}" \
  sh -s < "${HERE}/node-setup.sh" >/dev/null
for tag in signed unsigned rogue; do
  node test ! -e "$(path_of "${tag}")" || fail "$(path_of "${tag}") is still on the node"
done

envsubst < "${HERE}/proof-pool.yaml" | k apply -f - >/dev/null
k -n ate-nix-proof rollout status deployment/nix-proof --timeout=180s >/dev/null
ate get atespace ate-nix-proof >/dev/null 2>&1 || ate create atespace ate-nix-proof >/dev/null

# Prints the template's status once it has a golden snapshot or an error.
settle() {
  local status
  for _ in $(seq 60); do
    status="$(ate get actor-template "$1" -a ate-nix-proof -o yaml)"
    grep -qE 'snapshotTime|[Ee]rror|Crashed' <<<"${status}" && break
    sleep 2
  done
  echo "${status}"
}

for tag in signed unsigned rogue; do
  PROOF_IMAGE="$(path_of "${tag}")"
  export PROOF_IMAGE
  template="private-${tag}-${run}"
  echo "== ${tag}: nix:${PROOF_IMAGE}"
  envsubst < "${HERE}/proof-template.yaml" | sed "s/^  name: nix-proof$/  name: ${template}/" |
    ate create actor-template -f - >/dev/null
  status="$(settle "${template}")"
  if [[ "${tag}" == signed ]]; then
    grep -q snapshotTime <<<"${status}" || fail "the signed image did not boot: ${status}"
    node env NIX_REMOTE=daemon /nix/var/nix/profiles/default/bin/nix \
      --extra-experimental-features nix-command path-info --sigs "${PROOF_IMAGE}" |
      grep -q "${public_key%%:*}:" || fail "the signed image is on the node without the trusted signature"
    echo "   booted; on the node with a ${public_key%%:*} signature"
  else
    ! grep -q snapshotTime <<<"${status}" || fail "the ${tag} image booted"
    node test ! -e "${PROOF_IMAGE}" || fail "the ${tag} image reached the node's store"
    echo "   refused; not in the node's store"
    grep -E 'signature|substituter' <<<"${status}" | sed 's/^ */   /' | cut -c1-200
  fi
done

echo "PASS"
