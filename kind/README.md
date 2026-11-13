# Proof on kind

Starts an actor from a Nix store path on a throwaway local cluster, using upstream's own kind flow.
Needs Docker, Go, `kubectl`, `envsubst` and `curl`. No Nix on the host: Nix runs in a container and its store lives in a Docker volume that the kind node mounts as `/nix`.

All `nix` commands below run as:

```sh
nixc() { docker run --rm -v ate-nix-store:/nix -v "$PWD:/src" -w /src nixos/nix:latest \
  sh -c 'git config --global --add safe.directory /src; nix --extra-experimental-features "nix-command flakes" "$@"' nix "$@"; }
```

## 1. Build

In this repository. The first run fills the `ate-nix-store` volume with the image's Nix installation.

```sh
nixc build --no-link --print-out-paths .#proof-image .#atelet-image .#ateapi-image
```

Copy the two image tarballs out of the volume (`docker run -v ate-nix-store:/nix -v /tmp/out:/out busybox cp -L <path> /out/`). Keep the `ate-proof-image` path for step 5.

## 2. Cluster

In a checkout of `agent-substrate/substrate` at `v1.0.0`:

```sh
git apply /path/to/ate-nix/kind/create-kind-cluster.patch   # mounts the volume into the node as /nix
export KIND_CLUSTER_NAME=ate-nix ATE_INSTALL_KIND=true BUILDX_BUILDER=default
hack/create-kind-cluster.sh
go run ./cmd/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
go run ./cmd/ate-setup deploy demo counter      # OCI baseline, and a worker image to reuse
go build -o ~/bin/kubectl-ate ./cmd/kubectl-ate
```

`BUILDX_BUILDER=default` matters when your default buildx builder is a `docker-container` one: it cannot reach the registry on `localhost:5001`.

## 3. Node

```sh
docker exec -i ate-nix-control-plane sh < kind/node-setup.sh
```

## 4. Patched atelet and ateapi

```sh
hack/kind.sh load image-archive atelet-image.tar.gz --name ate-nix     # from the substrate checkout
hack/kind.sh load image-archive ateapi-image.tar.gz --name ate-nix
k() { kubectl --context kind-ate-nix -n ate-system "$@"; }
k patch ds atelet --type=json --patch-file kind/atelet-nix.patch.json
k set image ds/atelet atelet=docker.io/ate-nix/atelet:1.0.0
k set image deploy/ate-api-server ate-api-server=docker.io/ate-nix/ateapi:1.0.0
k rollout status ds/atelet && k rollout status deploy/ate-api-server
```

## 5. Prove

```sh
export PROOF_IMAGE=/nix/store/...-ate-proof-image
export WORKER_IMAGE=$(kubectl --context kind-ate-nix -n ate-demo-counter get workerpool counter -o jsonpath='{.spec.workerImage}')
kind/prove.sh
```

```text
== worker pool
== template from nix:/nix/store/ih3jm9l6cvyxl0iq5jcr513pqdv3qhzb-ate-proof-image
== actor
   actor sees 8 store paths; the node has 1861
== suspend, resume
   counter 3 -> 5
PASS
```

To see substitution, create a template whose image is a nixpkgs path the node does not have, for example `nixc eval --raw --inputs-from . nixpkgs#darkhttpd.outPath` with `command: ["/bin/darkhttpd", "/bin", "--port", "80"]`.

## 6. Private signed cache

```sh
kind/private-cache.sh      # same WORKER_IMAGE as step 5
```

Builds three images no public cache has and serves them from a local binary cache (container `ate-nix-cache` on the `kind` network): one signed with a new key, one unsigned, one signed with a second key. It adds the cache and the first key to the node with `kind/node-setup.sh`, which is how you point a real node at your own cache:

```sh
SUBSTITUTERS="https://cache.nixos.org https://cache.example.com" \
TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= example-1:..." \
  sh kind/node-setup.sh
```

```text
== signed: nix:/nix/store/0wb7h09wclmh342dk1jxjnrqbbifcm2j-ate-private-signed
   booted; on the node with a ate-proof-1 signature
== unsigned: nix:/nix/store/jcvyz3wagbpgd4m7kmghj15hgcimqfpw-ate-private-unsigned
   refused; not in the node's store
   error: path '...-ate-private-unsigned' is required, but there is no substituter that can build it
== rogue: nix:/nix/store/gvcx3h1m3bvh905i7y13wb3kcdj5jhlj-ate-private-rogue
   refused; not in the node's store
   error: path '...-ate-private-rogue' is required, but there is no substituter that can build it
PASS
```

## Teardown

```sh
KIND_CLUSTER_NAME=ate-nix hack/delete-kind-cluster.sh
docker rm -f ate-nix-cache
docker volume rm ate-nix-store ate-nix-cache
```
