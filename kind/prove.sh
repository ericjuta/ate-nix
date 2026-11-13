#!/usr/bin/env bash
# End-to-end proof on a kind cluster that an actor runs from a Nix store path.
# See kind/README.md for the cluster this expects.
#
#   PROOF_IMAGE=$(nix build --print-out-paths .#proof-image) kind/prove.sh
#
# Needs kubectl, kubectl-ate, envsubst, curl and docker on PATH.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-ate-nix}"
CONTEXT="kind-${KIND_CLUSTER_NAME}"
NODE="${NODE:-${KIND_CLUSTER_NAME}-control-plane}"
PORT="${PORT:-8017}"
: "${PROOF_IMAGE:?set PROOF_IMAGE to the store path of .#proof-image}"
# Any pool's worker image will do: the worker is not patched.
: "${WORKER_IMAGE:?set WORKER_IMAGE to an ateworker-gvisor image reference}"
export PROOF_IMAGE WORKER_IMAGE

k() { kubectl --context "${CONTEXT}" "$@"; }
ate() { kubectl ate --context "${CONTEXT}" "$@" 2> >(grep -v 'no --token-file given' >&2); }
node() { docker exec "${NODE}" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

run="$(date +%s)"
template="nix-proof-${run}"
actor="nix-proof-${run}"
actor2="nix-proof-${run}-b"
proxy_pid=""
proxy2_pid=""
cleanup() {
  [[ -n "${proxy_pid}" ]] && kill "${proxy_pid}" 2>/dev/null || true
  [[ -n "${proxy2_pid}" ]] && kill "${proxy2_pid}" 2>/dev/null || true
  ate delete actor "${actor}" -a ate-nix-proof >/dev/null 2>&1 || true
  ate delete actor "${actor2}" -a ate-nix-proof >/dev/null 2>&1 || true
  ate delete actor-template "${template}" -a ate-nix-proof >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== worker pool"
envsubst < "${HERE}/proof-pool.yaml" | k apply -f - >/dev/null
# The controller creates the Deployment a moment after the WorkerPool.
for _ in $(seq 30); do
  k -n ate-nix-proof get deployment/nix-proof >/dev/null 2>&1 && break
  sleep 1
done
k -n ate-nix-proof rollout status deployment/nix-proof --timeout=180s >/dev/null
ate get atespace ate-nix-proof >/dev/null 2>&1 || ate create atespace ate-nix-proof >/dev/null

echo "== template from nix:${PROOF_IMAGE}"
envsubst < "${HERE}/proof-template.yaml" | sed "s/^  name: nix-proof$/  name: ${template}/" |
  ate create actor-template -f - >/dev/null
# The golden snapshot is the first boot of the image: atelet builds the view,
# the worker mounts it, and the wakeup probe has to get an answer from it.
for _ in $(seq 60); do
  status="$(ate get actor-template "${template}" -a ate-nix-proof -o yaml)"
  grep -q snapshotTime <<<"${status}" && break
  sleep 2
done
grep -q snapshotTime <<<"${status}" || fail "no golden snapshot: ${status}"

echo "== actor"
ate create actor "${actor}" -a ate-nix-proof --template "${template}" >/dev/null
# Not through ate(): its stderr filter runs the command in a subshell, and
# killing that subshell would leave the proxy running.
kubectl ate --context "${CONTEXT}" proxy actor "${actor}" "${PORT}:80" -a ate-nix-proof >/dev/null 2>&1 &
proxy_pid=$!
url="http://127.0.0.1:${PORT}/cgi-bin/info"
before=""
for _ in $(seq 30); do
  kill -0 "${proxy_pid}" 2>/dev/null || fail "the proxy exited; is port ${PORT} taken?"
  before="$(curl -fsS -m 30 "${url}" 2>/dev/null)" && break
  sleep 1
done
[[ -n "${before}" ]] || fail "the actor did not answer"

closure="$(node env NIX_REMOTE=daemon /nix/var/nix/profiles/default/bin/nix-store --query --requisites "${PROOF_IMAGE}" | sort)"
seen="$(sed -n 's|^store_path=|/nix/store/|p' <<<"${before}" | sort)"
[[ "${seen}" == "${closure}" ]] ||
  fail "the actor's store is not exactly the closure"$'\n'"$(diff <(echo "${closure}") <(echo "${seen}"))"
[[ "$(field sh "${before}")" == /nix/store/* ]] || fail "/bin/sh does not resolve into the store"
echo "   actor sees $(wc -l <<<"${seen}") store paths; the node has $(node sh -c 'ls /nix/store | wc -l')"

echo "== store writes"
# The view's files are hard links to the node's store. The actor, as root,
# tries to change one, replace it, and add a store entry. Whatever the actor
# then sees in its own writable layer, nothing may reach the node's store, the
# view, or a second actor that starts from the same image.
nix_store() { node env NIX_REMOTE=daemon /nix/var/nix/profiles/default/bin/nix-store "$@"; }
[[ "$(field canary "${before}")" == original ]] || fail "the canary file is not readable in the actor"
tamper="$(curl -fsS -m 30 "http://127.0.0.1:${PORT}/cgi-bin/tamper")" || fail "the tamper request failed"
canary_path="$(field canary_path "${tamper}")"
[[ "${canary_path}" == /nix/store/*/share/ate-proof/canary ]] || fail "unexpected canary path: ${canary_path}"
view="/nix/var/ate/views/views/$(basename "${PROOF_IMAGE}")/fs"
[[ "$(node cat "${canary_path}")" == original ]] || fail "the actor changed the canary in the node's store"
[[ "$(node cat "${view}${canary_path}")" == original ]] || fail "the actor changed the canary in the view"
node test ! -e /nix/store/ate-proof-tamper || fail "the actor created an entry in the node's store"
node test ! -e "${view}/nix/store/ate-proof-tamper" || fail "the actor created an entry in the view"
# Compares every file of the closure with the hash Nix recorded for it.
# shellcheck disable=SC2086 # one argument per store path
nix_store --verify-path ${closure} || fail "a store path of the closure no longer matches its recorded hash"
ate create actor "${actor2}" -a ate-nix-proof --template "${template}" >/dev/null
kubectl ate --context "${CONTEXT}" proxy actor "${actor2}" "$((PORT + 1)):80" -a ate-nix-proof >/dev/null 2>&1 &
proxy2_pid=$!
second=""
for _ in $(seq 30); do
  kill -0 "${proxy2_pid}" 2>/dev/null || fail "the second proxy exited; is port $((PORT + 1)) taken?"
  second="$(curl -fsS -m 30 "http://127.0.0.1:$((PORT + 1))/cgi-bin/info" 2>/dev/null)" && break
  sleep 1
done
[[ "$(field canary "${second}")" == original ]] || fail "a second actor sees the first actor's change: $(field canary "${second}")"
[[ "$(sed -n 's|^store_path=|/nix/store/|p' <<<"${second}" | sort)" == "${closure}" ]] ||
  fail "a second actor sees a store that the first actor changed"
echo "   uid $(field uid "${tamper}"): append $(field append "${tamper}"), replace $(field replace "${tamper}"), create $(field create "${tamper}"); the actor now reads '$(field canary "${tamper}")'"
echo "   node store, view and a second actor: unchanged"

echo "== suspend, resume"
ate suspend actor "${actor}" -a ate-nix-proof >/dev/null
after="$(curl -fsS -m 60 "${url}")" || fail "the actor did not answer after resume"
(( $(field count "${after}") > $(field count "${before}") )) ||
  fail "the counter did not survive suspend: $(field count "${before}") then $(field count "${after}")"
echo "   counter $(field count "${before}") -> $(field count "${after}")"

echo "PASS"
