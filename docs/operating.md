# Enable Nix images on your cluster

Let actors start from `image: nix:/nix/store/...` on a cluster that already runs Agent Substrate v1.0.1.
There are three steps: prepare each node, replace two components, and give one of them the Nix store.

- No Substrate yet, on your own cluster: install it first with [install.md](install.md).
- You only want to try it: the local cluster in [../kind/README.md](../kind/README.md) does all three steps for you.

## Requirements

- A cluster that runs Substrate v1.0.1.
- Nix on each node that runs Nix images. NixOS is not required: any Linux distribution with a Nix installation works.
- A binary cache that the nodes can reach, and its public signing key. For packages from the public Nix package set, `cache.nixos.org` is enough.

Nix and a binary cache are needed only for Nix **actor** images. Substrate's own pods continue to use their container images.

## 1. Prepare each node

A node needs:

1. **A running Nix daemon** whose configuration lists your caches (`substituters`) and your keys (`trusted-public-keys`), with `require-sigs = true`. The trust rules are here and only here.
2. **A view directory on the same underlying filesystem as `/nix/store`**,
   for example `/nix/var/ate/views`. Views are made of hard links.
3. **A non-recursive, private bind of `/nix` at `/var/lib/ate-nix`**.
   Mount this alias into atelet as `/nix`, not the original host path.
   NixOS can bind `/nix/store` read-only beneath `/nix`; a recursive hostPath
   mount copies that child mount into the pod. The store and view directory
   then belong to different mount objects, so hard links fail with `EXDEV`
   even when their underlying filesystem is the same. The non-recursive
   alias excludes that child mount, and private propagation keeps later
   source-side child mounts out as well. A separately mounted store on a
   different underlying filesystem still cannot share hard-link views here.
4. **The view directory bind-mounted under `/var/lib/ate`**, for example at
   `/var/lib/ate/nix-views`. Worker pods mount only `/var/lib/ate` from the
   host, so this is how they see the views.

### On any distribution

`kind/node-setup.sh` does all four. Run it as root on the node. It expects a standard Nix installation in `/nix` and installs nothing.

```sh
SUBSTITUTERS="https://cache.nixos.org https://cache.example.com" \
TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= example-1:..." \
  sh kind/node-setup.sh
```

Without the two variables, the script trusts `cache.nixos.org` only.
The script is safe to run again. If the cache list or the key list changes, it restarts the daemon, because the daemon reads its configuration only when it starts.

The script starts the daemon with `systemd-run`, makes both bind mounts with
`mount --bind`, and makes `/var/lib/ate-nix` private. These changes do not
survive a reboot. For a long-lived node, configure a daemon unit and both
mounts in the node's own configuration. The alias must use `bind,private`,
never `rbind`; the view-directory bind remains unchanged.

### On NixOS

```nix
imports = [ inputs.ate-nix.nixosModules.ate-node ];

services.ate-node.nixImages = {
  enable = true;
  substituters = [ "https://cache.example.com" ];
  trustedPublicKeys = [ "example-1:..." ];
  # viewDir = "/nix/var/ate/views";        # default
  # mountDir = "/var/lib/ate/nix-views";   # default
};
```

The module creates the same non-recursive, private alias and view-directory
bind as the script, as persistent filesystem mounts. The DaemonSet must use
the alias hostPath described below, even on NixOS.

Before updating atelet, inspect the mount topology on each node:

```sh
findmnt --submounts --mountpoint /var/lib/ate-nix \
  --output TARGET,SOURCE,PROPAGATION
findmnt --mountpoint /var/lib/ate/nix-views --output TARGET,SOURCE
```

The first command should show a private alias mount, with **no child mount at
`/var/lib/ate-nix/store`**. The second should show the view-directory bind
(adjust its path if you changed `mountDir`). These checks establish the mount
topology, not actor correctness; the actor start/suspend/resume proof below
still needs to succeed.

## 2. Replace atelet and ateapi

These two components implement the Nix actor-image source. The portable
release also patches the shared worker overlay mount code; publish both worker
images from `ate-substrate.patchedSrc` when using older kernels, as described
in [install.md](install.md#publish-a-complete-oci-release). A full portable release already contains the required atelet/ateapi
changes, so skip the image replacement if you installed that release.

| Component | Why it is patched |
| --- | --- |
| `atelet` | Builds the views. |
| `ateapi` | Accepts `nix:` references. The upstream one rejects them. |

Build the images, then push them to a registry that your nodes can pull from:

```sh
nix build .#atelet-image && docker load < result    # ate-nix/atelet:1.0.1
nix build .#ateapi-image && docker load < result    # ate-nix/ateapi:1.0.1
for i in atelet ateapi; do
  docker tag ate-nix/$i:1.0.1 <registry>/ate-nix/$i:1.0.1
  docker push <registry>/ate-nix/$i:1.0.1
done
```

The images use the same layout as the upstream images (`/ko-app/<name>`), so only the image reference changes:

```sh
kubectl -n ate-system set image ds/atelet atelet=<registry>/ate-nix/atelet:1.0.1
kubectl -n ate-system set image deploy/ate-api-server ate-api-server=<registry>/ate-nix/ateapi:1.0.1
```

One difference from upstream: the atelet image has no C library. Upstream's has one so that atelet can run a dynamically linked kubelet credential provider for OCI pulls from a private registry (GKE Ubuntu, AKS). On such a node, pull OCI images from registries that need no credential provider, or build atelet on upstream's base image.

The overlayfs fallback runs in the **worker**, not atelet. Installing the
control plane does not rewrite existing WorkerPools. On an older kernel,
point each pool at the matching patched worker digest printed by the full OCI
publisher (choose `ateworker-microvm` for a microVM pool):

```sh
kubectl -n <atespace> patch workerpool <pool> --type=merge \
  -p '{"spec":{"workerImage":"registry.example.com/substrate/ateworker-gvisor@sha256:<published-digest>"}}'
```

Use the release's worker reference in new pool manifests as well. An
unpatched worker cannot gain the fallback by updating atelet or ateapi alone.

## 3. Give atelet the store

atelet needs the host's **`/var/lib/ate-nix` alias** mounted at container
`/nix`, and three arguments. Prepare the alias first; using a direct hostPath
of `/nix` reintroduces the NixOS read-only-child-mount hard-link failure.
The container paths do not change, so the daemon socket and `nix-store`
command remain accessible at their normal `/nix/...` paths:

| Argument | Value | Meaning |
| --- | --- | --- |
| `--nix-view-dir` | `/nix/var/ate/views` | Where atelet builds views. This argument enables Nix images. Without it, Nix images are off. |
| `--nix-view-mount-dir` | `/var/lib/ate/nix-views` | The path at which worker pods see the same directory. |
| `--nix-store-command` | `/nix/var/nix/profiles/default/bin/nix-store` | The `nix-store` program. On NixOS: `/nix/var/nix/profiles/system/sw/bin/nix-store`. |

`kind/atelet-nix.patch.json` is this change for the upstream DaemonSet:

```sh
kubectl -n ate-system patch ds atelet --type=json --patch-file kind/atelet-nix.patch.json
kubectl -n ate-system rollout status ds/atelet
```

atelet talks to the Nix daemon through the daemon's socket under `/nix/var/nix/daemon-socket`. It never writes to the store.

## Mixed clusters

A template with a Nix image that lands on a node without `--nix-view-dir` fails to start, and the error names the missing argument. If only some nodes have Nix, use a worker pool with a node selector and send Nix templates to that pool.

## Trust

- The node decides what to accept. A template cannot add a cache or a key.
- Trust is checked when a path is downloaded, not each time an actor starts. If you remove a key, paths that the node already has stay usable, and so do their views. To revoke an image, see the next section.
- With `require-sigs = true`, the daemon takes a path only if a key in `trusted-public-keys` signed it. An unsigned path and a path signed with an unknown key are both refused. [proof.md](proof.md) shows this test.
- Give the signing key to the system that builds images (CI), not to the nodes. Nodes need the public key only.
- A cache that needs a login is not tested. See [proof.md](proof.md).

## Revoke an image

Use this when an image, or a package inside images, must not run again: a leaked signing key, a bad build.

1. Stop the source. Remove the key from `trusted-public-keys` on each node and restart the Nix daemon, or delete the path from the cache. If you skip this step, the node downloads the path again on the next request.
2. On each node, run atelet one more time beside the running one. `--nix-revoke` makes it do one job and exit:

   ```sh
   kubectl -n ate-system exec <atelet pod on the node> -- /ko-app/atelet \
     --nix-view-dir=/nix/var/ate/views \
     --nix-store-command=/nix/var/nix/profiles/default/bin/nix-store \
     --nix-revoke=/nix/store/<hash>-<name>
   ```

   It removes each view that contains the path. Then it deletes the path, and each store path that depends on the path, from the node's store. If you revoke a package, all images on the node that contain the package go.
3. Delete the actors that run from a revoked image. Their files are gone.

After that, a request for the image is a new download, and the node applies its current trust rules. `kind/private-cache.sh` shows the full sequence.

If a store path that depends on the revoked path has another GC root (for example, a `result` link from a build on the node), Nix does not delete it. The views are removed, the command fails, and the error names the path. Remove the root and run the command again.

## Check that it works

Create a template from a path in the public cache and wait for its golden snapshot. `kind/prove.sh` does a full check: it starts an actor, compares what the actor sees with the closure, then suspends and resumes the actor. It expects the kind cluster of [../kind/README.md](../kind/README.md), but the template and pool files next to it (`kind/proof-template.yaml`, `kind/proof-pool.yaml`) work on any cluster.

For an installation from [install.md](install.md), use your S3 snapshot location and the patched
worker digest in the pool manifest. The checked-in Kind pool's worker
reference is not automatically replaced by `ate-setup`; using an upstream
worker on an older kernel would not exercise the compatibility patch.

If a template does not reach its golden snapshot, see [troubleshooting.md](troubleshooting.md).
