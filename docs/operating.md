# Run it on your cluster

What a cluster needs before a template can use `image: nix:/nix/store/...`.
For a complete worked example on a local cluster, see [../kind/README.md](../kind/README.md).

## Requirements

- A Kubernetes cluster with Agent Substrate v1.0.0 installed. Follow the upstream install guide at <https://ate.dev/docs/>.
- Nix on each node that runs Nix images. NixOS is not required: any Linux distribution with a Nix installation works.
- A binary cache that the nodes can reach, and its public signing key. For packages from the public Nix package set, `cache.nixos.org` is enough.

There are three steps: prepare the node, replace two Substrate binaries, change the atelet arguments.

## 1. Prepare each node

A node needs:

1. **A running Nix daemon** whose configuration lists your caches (`substituters`) and your keys (`trusted-public-keys`), with `require-sigs = true`. The trust rules are here and only here.
2. **A view directory on the same filesystem mount as `/nix/store`**, for example `/nix/var/ate/views`. Views are made of hard links, and a hard link cannot cross a mount.
3. **The view directory bind-mounted under `/var/lib/ate`**, for example at `/var/lib/ate/nix-views`. Worker pods mount only `/var/lib/ate` from the host, so this is how they see the views.

### On any distribution

`kind/node-setup.sh` does all three. Run it as root on the node. It expects a standard Nix installation in `/nix` and installs nothing.

```sh
SUBSTITUTERS="https://cache.nixos.org https://cache.example.com" \
TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= example-1:..." \
  sh kind/node-setup.sh
```

Without the two variables, the script trusts `cache.nixos.org` only.
The script is safe to run again. If the cache list or the key list changes, it restarts the daemon, because the daemon reads its configuration only when it starts.

The script starts the daemon with `systemd-run` and makes the bind mount with `mount --bind`. Neither survives a reboot. For a long-lived node, put both into your node's own configuration (a systemd unit and an `/etc/fstab` line).

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

The module is written from the same rules as the script. It has not been evaluated on a NixOS machine yet.

## 2. Replace atelet and ateapi

Two Substrate components are patched. All other components run unchanged from the upstream release.

| Component | Why it is patched |
| --- | --- |
| `atelet` | Builds the views. |
| `ateapi` | Accepts `nix:` references. The upstream one rejects them. |

Build the images and load them into your registry:

```sh
nix build .#atelet-image && docker load < result    # ate-nix/atelet:1.0.0
nix build .#ateapi-image && docker load < result    # ate-nix/ateapi:1.0.0
```

The images use the same layout as the upstream images (`/ko-app/<name>`), so only the image reference changes:

```sh
kubectl -n ate-system set image ds/atelet atelet=<registry>/ate-nix/atelet:1.0.0
kubectl -n ate-system set image deploy/ate-api-server ate-api-server=<registry>/ate-nix/ateapi:1.0.0
```

One difference from upstream: the atelet image has no C library. Upstream's has one so that atelet can run a dynamically linked kubelet credential provider for OCI pulls from a private registry (GKE Ubuntu, AKS). On such a node, pull OCI images from registries that need no credential provider, or build atelet on upstream's base image.

## 3. Give atelet the store

atelet needs the host's `/nix` mounted at `/nix`, and three arguments:

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
- With `require-sigs = true`, the daemon takes a path only if a key in `trusted-public-keys` signed it. An unsigned path and a path signed with an unknown key are both refused. [proof.md](proof.md) shows this test.
- Give the signing key to the system that builds images (CI), not to the nodes. Nodes need the public key only.
- A cache that needs a login is not tested. See [proof.md](proof.md).

## Check that it works

Create a template from a path in the public cache and wait for its golden snapshot. `kind/prove.sh` does a full check: it starts an actor, compares what the actor sees with the closure, then suspends and resumes the actor. It expects the kind cluster of [../kind/README.md](../kind/README.md), but the template and pool files next to it (`kind/proof-template.yaml`, `kind/proof-pool.yaml`) work on any cluster.

If a template does not reach its golden snapshot, see [troubleshooting.md](troubleshooting.md).
