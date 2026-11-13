# Getting started

Build the patched binaries and look at them. This page needs no cluster.

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
| `.#ate-substrate` | `atelet` and `ateapi` from Substrate v1.0.0 with the Nix image source. See [nix-images.md](nix-images.md). |
| `.#atelet-image`, `.#ateapi-image` | Container images of those two binaries, as `docker load` tarballs. Linux only. |
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

## Next

- See an actor start from a store path on a local cluster: [../kind/README.md](../kind/README.md).
- Run it on a real cluster: [operating.md](operating.md).
