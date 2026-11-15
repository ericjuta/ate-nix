# Proof on kind

Starts an actor from a Nix store path on a throwaway local cluster, using upstream's own kind flow.
Needs Docker, Go, `kubectl`, `git`, `envsubst` and `curl`. You do not need to install `kind`: the upstream scripts bring their own (`hack/kind.sh`). No Nix on the host: Nix runs in a container and its store lives in a Docker volume that the kind node mounts as `/nix`.

Time: a fresh clone to a clean teardown took about 20 minutes on an 8-core machine on 2026-11-15, with the Docker base images and the Go module cache already on the machine. Allow more the very first time. Steps 1 and 2 are nearly all of it.

The steps use two directories: this repository (`$ATE_NIX`) and a checkout of upstream Substrate (`$SUBSTRATE`). Each step says where to run. Use one shell for all steps, because later steps use the variables of earlier ones.

All `nix` commands below run as:

```sh
nixc() { docker run --rm -v ate-nix-store:/nix -v "$PWD:/src" -w /src nixos/nix:latest \
  sh -c 'git config --global --add safe.directory /src; nix --extra-experimental-features "nix-command flakes" "$@"' nix "$@"; }
```

## 1. Build

In this repository. The first run fills the `ate-nix-store` volume with the image's Nix installation.

```sh
export ATE_NIX="$PWD" OUT=/tmp/ate-nix-out
mkdir -p "$OUT"
nixc build --no-link --print-out-paths .#proof-image .#atelet-image .#ateapi-image | tee "$OUT/paths"
```

The command prints three store paths. The results are in the volume, not on your disk. Copy the two container image tarballs out, and keep the path of the proof image for step 5:

```sh
for p in $(grep -e '-atelet.tar.gz$' -e '-ateapi.tar.gz$' "$OUT/paths"); do
  docker run --rm --user "$(id -u)" -v ate-nix-store:/nix -v "$OUT:/out" busybox cp -L "$p" /out/
done
export PROOF_IMAGE="$(grep -e '-ate-proof-image$' "$OUT/paths")"
ls "$OUT"; echo "$PROOF_IMAGE"
```

## 2. Cluster

Get upstream Substrate at `v1.0.0` and work in that checkout:

```sh
export SUBSTRATE=/tmp/ate-nix-substrate
git clone --branch v1.0.0 --depth 1 https://github.com/agent-substrate/substrate "$SUBSTRATE"
cd "$SUBSTRATE"
git apply "$ATE_NIX/kind/create-kind-cluster.patch"   # mounts the volume into the node as /nix
export KIND_CLUSTER_NAME=ate-nix ATE_INSTALL_KIND=true BUILDX_BUILDER=default
hack/create-kind-cluster.sh
go run ./cmd/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
go run ./cmd/ate-setup deploy demo counter      # OCI baseline, and a worker image to reuse
mkdir -p "$OUT/bin" && go build -o "$OUT/bin/kubectl-ate" ./cmd/kubectl-ate
export PATH="$OUT/bin:$PATH"                    # kubectl finds the plugin as `kubectl ate`
```

The install builds Substrate's own container images, so it is the slow part. The two flags on `deploy ate-system` are what upstream's kind flow uses: they are not specific to this repository.

`BUILDX_BUILDER=default` matters when your default buildx builder is a `docker-container` one: it cannot reach the registry on `localhost:5001`.

## 3. Node

From here on, work in this repository again. This step configures the Nix daemon and the mounts inside the kind node:

```sh
cd "$ATE_NIX"
docker exec -i ate-nix-control-plane sh < kind/node-setup.sh
```

## 4. Patched atelet and ateapi

In this repository. Load the two tarballs of step 1 into the kind node, then switch the two components to them. The upstream `hack/kind.sh` works only from its own checkout, so the two load lines change directory for one command each:

```sh
(cd "$SUBSTRATE" && hack/kind.sh load image-archive "$OUT"/*-atelet.tar.gz --name ate-nix)
(cd "$SUBSTRATE" && hack/kind.sh load image-archive "$OUT"/*-ateapi.tar.gz --name ate-nix)
k() { kubectl --context kind-ate-nix -n ate-system "$@"; }
k patch ds atelet --type=json --patch-file kind/atelet-nix.patch.json
k set image ds/atelet atelet=docker.io/ate-nix/atelet:1.0.0
k set image deploy/ate-api-server ate-api-server=docker.io/ate-nix/ateapi:1.0.0
k rollout status ds/atelet && k rollout status deploy/ate-api-server
```

## 5. Prove

In this repository. `PROOF_IMAGE` is set since step 1.

```sh
export WORKER_IMAGE=$(kubectl --context kind-ate-nix -n ate-demo-counter get workerpool counter -o jsonpath='{.spec.workerImage}')
kind/prove.sh
```

```text
== worker pool
== template from nix:/nix/store/gib7cf9ahddb75mi25s30hwrmy55yffx-ate-proof-image
== actor
   actor sees 10 store paths; the node has 3749
== store writes
   uid 0: append refused, replace done, create done; the actor now reads 'tampered'
   node store, view and a second actor: unchanged
== suspend, resume
   counter 2 -> 4
PASS
```

The hash, the number of node paths and the counter values differ from run to run. `PASS` on the last line is the result.

Optional, and not scripted: to see substitution, create a template whose image is a nixpkgs path the node does not have, for example `nixc eval --raw --inputs-from . nixpkgs#darkhttpd.outPath` with `command: ["/bin/darkhttpd", "/bin", "--port", "80"]`.

## 6. Private signed cache

```sh
kind/private-cache.sh      # same WORKER_IMAGE as step 5
```

Builds three images no public cache has and serves them from a local binary cache (container `ate-nix-cache` on the `kind` network): one signed with a new key, one unsigned, one signed with a second key. It also asks for a store path that no cache has, and checks that each refused template's error says why. It adds the cache and the first key to the node with `kind/node-setup.sh`. You do not run the next block here: it shows how you point a real node at your own cache with the same script.

```sh
SUBSTITUTERS="https://cache.nixos.org https://cache.example.com" \
TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= example-1:..." \
  sh kind/node-setup.sh
```

```text
== signed: nix:/nix/store/mzdqh638x5z7lv167b59skx9s34q9khv-ate-private-signed
   booted; on the node with a ate-proof-1 signature
== unsigned: nix:/nix/store/7xz61x4n7b76fz4898ha4fvw492rc6hk-ate-private-unsigned
   refused; not in the node's store
   binary cache http://ate-nix-cache has /nix/store/7xz61x4n7b76fz4898ha4fvw492rc6hk-ate-private-unsigned, but it carries no signature (the node takes only paths signed by a key in its trusted-public-keys)
== rogue: nix:/nix/store/w7cy1ai1xhjinaj2p4nyjqpdam7s2d2w-ate-private-rogue
   refused; not in the node's store
   binary cache http://ate-nix-cache has /nix/store/w7cy1ai1xhjinaj2p4nyjqpdam7s2d2w-ate-private-rogue, signed only by keys this node does not trust: ate-rogue-1 (the node takes only paths signed by a key in its trusted-public-keys)
== missing: nix:/nix/store/a2937z795264b34300ba7661dd342101-ate-private-missing
   refused; not in the node's store
   no binary cache configured on this node has /nix/store/a2937z795264b34300ba7661dd342101-ate-private-missing
== revoke: the node stops trusting ate-proof-1
   the image the node already has still boots
   atelet: removed view mzdqh638x5z7lv167b59skx9s34q9khv-ate-private-signed
   atelet: revoked /nix/store/mzdqh638x5z7lv167b59skx9s34q9khv-ate-private-signed
   after atelet --nix-revoke: refused; not in the node's store
   binary cache http://ate-nix-cache has /nix/store/mzdqh638x5z7lv167b59skx9s34q9khv-ate-private-signed, signed only by keys this node does not trust: ate-proof-1 (the node takes only paths signed by a key in its trusted-public-keys)
PASS
```

The last block is revocation. The script takes the first key away from the node. The signed image is already on the node, so it still boots. `atelet --nix-revoke` removes it from the node, and after that the node refuses it. [../docs/operating.md](../docs/operating.md) has the procedure for a real cluster.

## Teardown

```sh
(cd "$SUBSTRATE" && KIND_CLUSTER_NAME=ate-nix hack/delete-kind-cluster.sh)
docker rm -f ate-nix-cache
docker volume rm ate-nix-store ate-nix-cache
rm -rf "$OUT" "$SUBSTRATE"
```

If `docker volume rm` says that `ate-nix-store` is in use, a stopped container still holds it: `docker ps -a --filter volume=ate-nix-store` shows it, and `docker rm <id>` removes it.
The upstream install also leaves an image tag `localhost:5001/envoy-dataplane:build-<number>` in your local Docker. `docker image ls 'localhost:5001/*'` shows it.
