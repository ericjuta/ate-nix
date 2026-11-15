# Getting started

Build the patched programs and look at them. Nothing on this page needs a cluster.

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

`ate-setup` is the Substrate installer and `kubectl-ate` is its `kubectl` plugin. [install.md](install.md) uses them.

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
mkdir -p /tmp/ate-nix-bin
docker run --rm --user "$(id -u)" -v ate-nix-store:/nix -v /tmp/ate-nix-bin:/out busybox cp -L <store path>/bin/ate-env /out/
/tmp/ate-nix-bin/ate-env --help
```

Use the store path that ends in `-ate-env-...`. The programs are statically linked, so the copy runs on any Linux host of the same architecture.

## What you can build

| Output | What it is |
| --- | --- |
| `.#ate-env` (default) | `ate-env`, `ate-env-api`, `ate-env-guest` with PTY streams. See [pty.md](pty.md). |
| `.#ate-substrate` | `atelet`, `ateapi`, `ate-setup`, and `kubectl-ate` from patched Substrate v1.0.0. The installer supports `--existing-cluster`; see [install.md](install.md). |
| `.#ate-substrate.patchedSrc` | The exact patched source and runtime resources, including the worker overlayfs compatibility patch. Use this source to publish a complete OCI release, not just the two binary images below. |
| `.#atelet-image`, `.#ateapi-image` | Container images of those two binaries, as `docker load` tarballs. Linux only. |
| `.#ate-env-api-image` | Container image of the patched `ate-env-api`, as a `docker load` tarball. Linux only. |
| `.#example-image` | A small Nix image: bash and coreutils. |
| `.#proof-image` | The Nix image that the local proof starts: a small HTTP server. |
| `.#omp-image` | A Nix image with the OMP coding agent and the env guest. Linux only. See [../examples/omp/README.md](../examples/omp/README.md). |
| `.#substrate-nix-bundle` | Every Substrate system pod, worker and demo actor as Nix closures, with the installer image map. Linux only. See [nix-images.md](nix-images.md#registry-free-substrate-system-pods). |
| `.#substrate-image-map`, `.#substrate-image-map-check` | The image map alone, and the test that checks each entry of the built map. Linux only. |
| `.#nix-snapshotter` | The pinned nix-snapshotter that the registry-free path uses. Linux only. |
| `.#substrate-installer-tests`, `.#substrate-envoy-module-check` | Test-only outputs: the installer's test packages, and a load test of the Envoy module. Linux only. |

[concepts.md](concepts.md#other-names-you-will-meet) defines OMP, image map and nix-snapshotter.

### Time and disk

The first build of anything downloads a compiler toolchain, so it is the slow one. Later builds reuse the store.

| Build | From an empty store |
| --- | --- |
| `.#ate-env`, `.#ate-substrate`, the three container images, `.#example-image`, `.#proof-image` | Minutes. These compile Go programs only. |
| `.#omp-image` | More than an hour on an 8-core machine. It compiles a Rust toolchain and OMP's native code. |
| `.#substrate-nix-bundle` | About an hour on the 4-core CI machines. It compiles Jaeger, the OpenTelemetry Collector and an Envoy module. |
| `nix flake check` (everything) | 86 to 107 minutes on the 4-core CI machines. The compressed result is 4 to 5 GB for each system; allow 20 GB of disk. |

You need the last three only for OMP, for the registry-free path, or to send a change.

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

## Next

- See an actor start from a store path on a local cluster: [../kind/README.md](../kind/README.md).
- Install Substrate on a cluster that you already have: [install.md](install.md).
- Enable Nix images on a cluster that runs Substrate: [operating.md](operating.md).
