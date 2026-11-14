# Getting started

Build the patched binaries and deployment tools. The build and help commands
on this page need no cluster. [operating.md](operating.md) covers installing
Substrate on an existing non-GKE cluster as well as enabling Nix actor images.

## Requirements

One of these:

- **Nix** with flakes enabled, on Linux x86_64.
- **Docker** only. Nix then runs in a container.

CI builds and tests `x86_64-linux` and `aarch64-linux`. Only `x86_64-linux` has run on a cluster. The flake also declares `aarch64-darwin`. Nobody has built it.

## Get the source

```sh
git clone https://github.com/ericjuta/ate-nix
cd ate-nix
```

## Build with Nix

```sh
nix build .#ate-env
./result/bin/ate-env --help

nix build .#ate-substrate
./result/bin/atelet --help | grep nix

# The installer carries its pinned manifests and helper resources. It does not
# need this checkout as its working directory.
ATE_PACKAGE="$(nix build --no-link --print-out-paths .#ate-substrate)"
(
  cd /tmp
  "$ATE_PACKAGE/bin/ate-setup" --help
  "$ATE_PACKAGE/bin/kubectl-ate" --help
)
```

The first build downloads the upstream source and compiles it. The build also runs the Go tests of the patched packages. A failed test fails the build.

## Build without Nix on the host

Define this shell function. It runs Nix in a container and keeps the Nix store in a Docker volume named `ate-nix-store`, so the second build is fast.

```sh
nixc() { docker run --rm -v ate-nix-store:/nix -v "$PWD:/src" -w /src nixos/nix:latest \
  sh -c 'git config --global --add safe.directory /src; nix --extra-experimental-features "nix-command flakes" "$@"' nix "$@"; }
```

Then:

```sh
nixc build --no-link --print-out-paths .#ate-env .#ate-substrate
```

The command prints the store paths of the results. They are in the volume, not on your disk. To copy a file to the host:

```sh
docker run --rm -v ate-nix-store:/nix -v "$PWD/out:/out" busybox cp -L <store path>/bin/ate-env /out/
```

## What you can build

| Output | What it is |
| --- | --- |
| `.#ate-env` (default) | `ate-env`, `ate-env-api`, `ate-env-guest` with PTY streams. See [pty.md](pty.md). |
| `.#ate-substrate` | `atelet`, `ateapi`, `ate-setup`, and `kubectl-ate` from patched Substrate v1.0.0. The installer supports `--existing-cluster`; see [operating.md](operating.md). |
| `.#ate-substrate.patchedSrc` | The exact patched source and runtime resources, including the worker overlayfs compatibility patch. Use this source to publish a complete OCI release, not just the two binary images below. |
| `.#atelet-image`, `.#ateapi-image` | Container images of those two binaries, as `docker load` tarballs. Linux only. |
| `.#ate-env-api-image` | Container image of the patched `ate-env-api`, as a `docker load` tarball. Linux only. |
| `.#example-image` | A small Nix image: bash and coreutils. |
| `.#proof-image` | The Nix image that the local proof starts: a small HTTP server. |

Check that all outputs evaluate, without a build:

```sh
nix flake check --no-build
```

Without `--no-build`, the same command builds and tests everything for your system. That is what CI runs.

For a complete project on top of this flake (a dev shell, an app and two actor images from one lock file), see [../examples/reference/README.md](../examples/reference/README.md).

## Use it from your own flake

```nix
{
  inputs.ate-nix.url = "github:ericjuta/ate-nix";

  outputs = { nixpkgs, ate-nix, ... }: {
    # ...
    # nixpkgs.overlays = [ ate-nix.overlays.default ];
    # then: pkgs.ate-env, pkgs.ate-substrate, pkgs.ateNixImage, pkgs.ateImages
  };
}
```

`pkgs.ateNixImage` is the function that builds a Nix image. [nix-images.md](nix-images.md) shows how to call it.
On NixOS nodes, `ate-nix.nixosModules.ate-node` prepares the node. [operating.md](operating.md) shows the options.

## Install outside GKE

The packaged `ate-setup` preserves upstream defaults: `--kind` selects the
local development profile, and omitting both profile flags keeps the GKE path.
`--existing-cluster` (or `existingCluster: {enabled: true}` in a `SubstrateInstall` file)
intentionally selects an already-provisioned non-GKE cluster. It uses
kubeconfig and an operator-managed S3 Secret, without Docker/Kind preflight,
a local registry, or bundled development services.

A prebuilt gVisor installation uses upstream `--image-repo` and `--image-tag`
with `--sandbox-classes=gvisor`, so the operator needs neither Go/ko nor
Docker. The explicit sandbox selection avoids the upstream GKE/Kind-specific
microVM asset bootstrap. Someone must first publish the
**complete patched release**, including both worker images and
`envoy-dataplane`. The two OCI tarballs exported by this flake are not a
complete release. [operating.md](operating.md#publish-a-complete-oci-release)
gives the full build/publish command using the exposed patched source and the
package's Go development environment.

The cluster must provide the required certificate APIs and feature gates;
ordinary Kubernetes access alone is not sufficient. Follow the
[cluster prerequisites](operating.md#cluster-prerequisites) before deploying.

## Next

- See an actor start from a store path on a local cluster: [../kind/README.md](../kind/README.md).
- Run it on a real cluster: [operating.md](operating.md).
