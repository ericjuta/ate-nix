# ate-nix

Agent Substrate ([ate.dev](https://ate.dev)) with Sam Huber's patch stack, packaged as a Nix overlay.
No fork, no cloned tree: upstream is pinned by hash and the changes live here as patch files.

Two patch sets:

| Package | Upstream | Adds |
| --- | --- | --- |
| `ate-env` | `agent-substrate/env` | PTY process streams. Sam's gist patch, rebased. |
| `ate-substrate` | `agent-substrate/substrate` v1.0.0 | Nix store paths as actor images, replacing the mandatory OCI path. Written here from Sam's description; his own patch is not public. |

## Nix images (`ate-substrate`)

Sam's goal, from his Discord notes: one artifact type (store paths), one distribution system (the binary cache), no registry and no per-run image pull.
A template is a Nix expression built ahead of time; the actor spec carries only the closure's root store path; nodes substitute signed paths and expose the closure read-only.

`patches/substrate/0001-atelet-nix-image-source.patch` does that:

- A container `image` (or image volume) may be `nix:/nix/store/<hash>-<name>`. `ateapi` accepts it as pinned: the hash names the content.
- `atelet` asks the node's Nix daemon to substitute the closure (`nix-store --realise`, with a GC root), lists it (`nix-store --query --requisites`) and hard-links exactly those paths into a per-closure view.
- The view is handed to the worker as one overlay lowerdir through the existing `rootfs-overlay.json` contract. The gVisor and microVM workers are unchanged, and OCI images keep working beside Nix images.
- An actor sees only its own closure, never the rest of the node's store. Nothing is evaluated or built on the node.
- Unused views and their GC roots are removed on the image cache GC schedule.
- Entrypoint, env, working directory and user come from an optional `ate-image-config.json` in the root path, in OCI config shape.

The full operator guide is added by the patch as `docs/guides/nix-images.md`.

### Build an image

```nix
pkgs.ateNixImage {
  name = "agent-env";
  paths = [ pkgs.bashInteractive pkgs.coreutils pkgs.ripgrep ];
  config = { Entrypoint = [ "/bin/bash" ]; Env = [ "PATH=/bin" ]; };
}
```

Push the result to your binary cache, then use `image: nix:/nix/store/...-agent-env` in the ActorTemplate.
`nix build .#example-image` builds a small one.

### Node setup

Any Kubernetes node works, on any distro, as long as the node has Nix: a store, a running daemon with your cache and signing key configured, and the view directory bind-mounted under `/var/lib/ate`.
`kind/node-setup.sh` does that with plain shell. On NixOS the module does the same:

```nix
imports = [ inputs.ate-nix.nixosModules.ate-node ];
services.ate-node.nixImages = {
  enable = true;
  substituters = [ "https://cache.example.com" ];
  trustedPublicKeys = [ "cache.example.com-1:..." ];
};
```

This creates `/nix/var/ate/views` and bind-mounts it at `/var/lib/ate/nix-views`, where worker pods already look.
Then run the patched `atelet` with the host's `/nix` mounted and:

```text
--nix-view-dir=/nix/var/ate/views
--nix-view-mount-dir=/var/lib/ate/nix-views
--nix-store-command=/nix/var/nix/profiles/system/sw/bin/nix-store
```

`kind/atelet-nix.patch.json` is that change as a JSON patch for the upstream atelet DaemonSet (it uses the default-profile `nix-store` of a standard Nix install).
Run the patched `ateapi` too, or it rejects `nix:` references.

### Container images

`nix build .#atelet-image` and `.#ateapi-image` build `docker load` tarballs of the two patched binaries, tagged `ate-nix/atelet:1.0.0` and `ate-nix/ateapi:1.0.0`.
They follow the upstream ko layout (`/ko-app/<name>`), so only the image reference changes in the upstream manifests:

```sh
kubectl -n ate-system set image ds/atelet atelet=<registry>/ate-nix/atelet:1.0.0
kubectl -n ate-system set image deploy/ate-api-server ate-api-server=<registry>/ate-nix/ateapi:1.0.0
```

The atelet image has no libc. Upstream's has glibc so that atelet can run a dynamically linked kubelet credential provider (GKE Ubuntu, AKS) for OCI pulls; on such a node, keep OCI pulls on public or pull-secret-free registries or use an image built from upstream's base.

### Proof

Proven on 2026-11-13 on a single-node kind cluster (Kubernetes v1.37.0, gVisor workers, Debian node with Nix 2.35.6), running the two images above. `kind/README.md` has the steps; `kind/prove.sh` is the check.

- **An actor boots from a store path.** The template's golden snapshot was taken from `nix:/nix/store/...-ate-proof-image` and the actor answered HTTP through the router.
- **The actor sees its closure and nothing else.** 8 store paths inside the actor, exactly `nix-store --query --requisites`; the node's store had 1861.
- **Suspend and resume work.** A counter in the actor's writable layer continued after `kubectl ate suspend actor`.
- **Substitution works.** Two paths that were not on the node (`darkhttpd`, `static-web-server`) were fetched from `cache.nixos.org`, signature-checked by the daemon, and booted in about 4 and 11 seconds.
- **A path no cache has fails cleanly.** The template reports `GoldenActorCrashed ... there is no substituter that can build it`.
- **OCI still works** next to it: the upstream counter demo ran on the same patched atelet.

Not proven: microVM workers (this host has no KVM), more than one node, view garbage collection over time, and a private signed cache (the test used `cache.nixos.org` and its key).

### What this does not cover

- **nix-snapshotter for ordinary Kubernetes pods.** That is node configuration ([pdtpartners/nix-snapshotter](https://github.com/pdtpartners/nix-snapshotter)), not a Substrate patch. The Substrate system pods themselves still ship as OCI images.
- **Agents adding tools at runtime** (a writable store view). The store is read-only inside the actor.

## PTY streams (`ate-env`)

### What you get

`nix build .#ate-env` produces `ate-env`, `ate-env-api` and `ate-env-guest` with:

- `ate-env <id> shell --tty <cmdline>`: a real remote PTY (raw byte stream, stdin, resize on SIGWINCH).
- `--suspend-on-osc-7501-inactive`: suspend the env actor after the PTY exits, if the program reported OSC 7501 inactive.
- `StartProcessRequest.pty` / `initial_size`, `TermSize` and the `ResizeProcess` RPC in the env API and guest.

## Pins

| What | Pin |
| --- | --- |
| `agent-substrate/env` | `56424de763f91daa6b6c38f6249bacef1d82e5e1` (main, 2026-11-01; no tag exists after `v0.0.10`) |
| `go.ate.dev/substrate` | `v1.0.0` (`b34fbee742906494b5eb4f1f36987176bf8770a4`), set by patch 0002 |
| `agent-substrate/substrate` | `v1.0.0` (`b34fbee742906494b5eb4f1f36987176bf8770a4`), source of `ate-substrate` |
| Sam's gist | https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96 at `a625acf1ae16dcc8015d10fed76cf7bd1a75d010` |

## Patches

- `patches/env/0001-pty-process-streams.patch`: Sam's `0001-companyos-pty-process-streams.patch`, rebased from env `281e860` onto `56424de`.
- `patches/env/0002-substrate-v1.0.0.patch`: `go.mod`/`go.sum` only. Moves the Substrate module from the v0.6.1 pre-release to v1.0.0. No source change was needed.

### What changed in the rebase

Sam's patch added router mTLS to `ate-env-api` (`-router-client-cert`, `-router-client-key`, `-router-ca`).
Upstream `56424de` ships the same thing natively, so that part of his patch is dropped.
Use the upstream flags instead:

```text
-atenet-credential-bundle=/run/substrate-router-client/credential-bundle.pem
-atenet-ca-file=/run/substrate-router-client/router-ca.pem
```

Sam's `deploy-omp-env-pty.sh` from the gist still passes the old flag names; change them before you use it with this build.
Everything else in his patch is applied unchanged.

## Use

```sh
nix build .#ate-env
./result/bin/ate-env --help
nix build .#ate-substrate
./result/bin/atelet --help | grep nix
```

As an overlay in another flake:

```nix
inputs.ate-nix.url = "github:<owner>/ate-nix";
# ...
nixpkgs.overlays = [ inputs.ate-nix.overlays.default ];  # then pkgs.ate-env, pkgs.ate-substrate, pkgs.ateNixImage
```

## Update

1. Change `rev` and `hash` in `pkgs/ate-env.nix`; set `vendorHash = lib.fakeHash`.
2. `nix build .#ate-env`. If a patch no longer applies, rework it against the new `rev`; do not loosen it with fuzz.
3. Copy the `got:` hash into `vendorHash` and build again. The build runs the Go tests of the patched packages.
