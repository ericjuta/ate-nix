# Maintaining and contributing

How the repository is laid out, how to move it to a new upstream release, and how to change a patch.

## Layout

```text
flake.nix                 outputs: packages, checks, overlay, NixOS module
pkgs/
  ate-env.nix             env binaries: upstream pin + patches/env
  ate-substrate.nix       atelet, ateapi, installer and plugin: upstream pin + patches/substrate
  ate-nix-image.nix       ateNixImage: builds a Nix image root
  omp-image.nix           generic OMP actor image with the env guest
  ate-images.nix          container images of atelet and ateapi
  nix-snapshotter/        pinned snapshotter, pause archive, containerd VM check
  registry-free-substrate/ closure-backed pod packages, actor roots and image map
patches/
  env/                    applied to agent-substrate/env
  substrate/              applied to agent-substrate/substrate
  nix-snapshotter/         generic upstream snapshotter fixes
modules/ate-node.nix      NixOS module for an actor node
modules/nix-snapshotter.nix optional standalone containerd/kubelet integration
kind/                     local proof: cluster patch, node setup, checks
examples/reference/       a project that uses this flake: dev shell, app, two images
examples/omp/             OMP actor template and terminal smoke
docs/                     this documentation
```

No upstream code is stored here. Each `pkgs/*.nix` file names an upstream commit (`rev`) and the hash of its source (`hash`). Nix refuses to build if the downloaded source does not match the hash.

## Pins

| What | Pin |
| --- | --- |
| `agent-substrate/substrate` | `v1.0.0`, commit `b34fbee742906494b5eb4f1f36987176bf8770a4` |
| `agent-substrate/env` | commit `56424de763f91daa6b6c38f6249bacef1d82e5e1` (main, 2026-11-01). No tag exists after `v0.0.10`. |
| `go.ate.dev/substrate` inside env | `v1.0.0`, set by `patches/env/0002-substrate-v1.0.0.patch` |
| Original PTY patch | <https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96> at revision `a625acf1ae16dcc8015d10fed76cf7bd1a75d010` |
| nix-snapshotter | `v0.4.0`; source and globset dependency hashes in `pkgs/nix-snapshotter/default.nix` |
| Oh My Pi | `18.20.2`, commit `7c49c11aa5bbaf3f418406583096168ad5b8c6dc`; upstream flake retains its own toolchain pins |
| `nixpkgs` | `nixos-unstable`, locked in `flake.lock` |

## Patches

| Patch | Applies to | Content |
| --- | --- | --- |
| `patches/substrate/0001-atelet-nix-image-source.patch` | substrate v1.0.0 | Nix store paths as actor images. Written for this repository. |
| `patches/substrate/0002-existing-cluster-installer.patch` | substrate v1.0.0 | Provider-neutral existing-cluster installation and pinned installer resources. |
| `patches/substrate/0003-overlayfs-legacy-fallback.patch` | substrate v1.0.0 | Legacy overlay mount compatibility with explicit option and path bounds. |
| `patches/substrate/0009-ate-setup-image-map.patch` | substrate v1.0.0 + existing-cluster profile | Installer component/exact-reference mapping without registry tag resolution; actor roots remain separate from pod archives. |
| `patches/nix-snapshotter/nix-snapshotter-183-store-path-mount-type.patch` | nix-snapshotter v0.4.0 | Store-path bind mount classification for containerd user/group lookup. |
| `patches/nix-snapshotter/nix-snapshotter-builder-error-output.patch` | nix-snapshotter v0.4.0 | Bounded substitution diagnostics returned to CRI callers. |
| `patches/env/0001-pty-process-streams.patch` | env `56424de` | PTY streams. Samuel Huber's patch, rebased. [pty.md](pty.md) lists the one part that was dropped. |
| `patches/env/0002-substrate-v1.0.0.patch` | env `56424de` | `go.mod` and `go.sum` only: Substrate v1.0.0. |
| `patches/env/0003-free-slot-before-exit.patch` | env `56424de` | The guest frees a process slot before it reports the exit. Without it, upstream `TestConcurrencyLimiter` fails on a loaded machine. |
| `patches/env/0004-router-tls-rotation.patch` | env `56424de` | Reload the router trust bundle and client credentials on TLS handshakes. |
| `patches/env/0005-resume-cut-process-streams.patch` | env `56424de` + PTY | Resume process output and stdin after router stream cuts. |

## Update a pin

Nix fixes each download by hash. When a pin changes, you set a placeholder hash, build once, and copy the correct hash from the error.

### env

1. In `pkgs/ate-env.nix`, set the new `rev`. Set `hash = lib.fakeHash;` and `vendorHash = lib.fakeHash;`.
2. `nix build .#ate-env`. The build fails and prints `got: sha256-...` for the source. Copy it into `hash`.
3. Build again. If a patch does not apply, see "Change a patch". If the patches apply, the build fails and prints `got:` for the Go dependencies. Copy it into `vendorHash`.
4. Build again. This build compiles and runs the tests.

### substrate

1. In `pkgs/ate-substrate.nix`, set the new `rev` and `version`. Set `hash = lib.fakeHash;`.
2. `nix build .#ate-substrate`. Copy the `got:` hash into `hash`.
3. Build again. `vendorHash` stays `null`: upstream commits its Go dependencies into the source tree.

After a substrate update, run the local proof in [../kind/README.md](../kind/README.md) again. A build proves that the patch applies and that its unit tests pass. It does not prove that an actor boots.

## Change a patch

Work in a checkout of the upstream repository, not here.

```sh
git clone https://github.com/agent-substrate/substrate && cd substrate
git checkout b34fbee742906494b5eb4f1f36987176bf8770a4          # the pin
git am /path/to/ate-nix/patches/substrate/0001-atelet-nix-image-source.patch
# edit, then test:
gofmt -l internal/niximage internal/nixref cmd/atelet internal/resources
go vet ./internal/niximage/ ./internal/nixref/ ./internal/resources/ ./cmd/atelet/
go test ./internal/niximage/ ./internal/nixref/ ./internal/resources/ ./internal/imagecache/
git commit -a --amend
git format-patch -1 --no-signature --stdout > /path/to/ate-nix/patches/substrate/0001-atelet-nix-image-source.patch
```

For a move to a new upstream commit, apply the patch at the old pin, then `git rebase` the commit onto the new one and solve the conflicts there.

Rules:

- A patch must apply with no fuzz and no rejected hunk. If it does not, rework it.
- If upstream now has a feature that a patch added, delete that part of the patch and use the upstream feature. This happened with the router TLS flags in the PTY patch.
- One patch per feature. Dependency changes (`go.mod`, `go.sum`) go into a separate patch.

## Before you send a change

```sh
nix flake check -L
(cd examples/reference && nix flake check -L)
```

The first command builds every check of the flake for your system: both packages with their Go tests, all images, ShellCheck on the `kind/` scripts, and an evaluation of the NixOS module. The second does the same for the reference project.
CI (`.github/workflows/ci.yml`) runs both on each pull request, on `x86_64-linux` and `aarch64-linux`. Linux checks also include image-map validation, an Envoy dynamic-module check, and a disposable NixOS VM with standalone containerd. That VM is not a complete Substrate/Kubernetes cluster. The VM check (`registry-free-node`) needs KVM, which the hosted ARM runner does not have, so CI runs it on `x86_64-linux` only. CI also removes unused toolchains from the runner and adds swap, because the collector and Jaeger builds need more disk and memory than a hosted runner has free.

- A change to the substrate patch needs the local proof (`kind/prove.sh`, `kind/private-cache.sh`). If you did not run it, say so.
- Update [proof.md](proof.md) only with results that you saw. Put all other items in "Not proven".
- Documentation uses plain words and defines each term once, in [concepts.md](concepts.md).

## Upstreaming

The best outcome for both patches is that upstream accepts them and this repository becomes unnecessary. Neither patch has been proposed upstream yet.

## Licence

This repository is Apache-2.0, the same licence as Agent Substrate and env: see [../LICENSE](../LICENSE) and [../NOTICE](../NOTICE). The patches are changes to that upstream code. A contribution that you send is under the same licence.

One point is open. The gist that contains the original PTY patch has no licence statement. `NOTICE` records this.
