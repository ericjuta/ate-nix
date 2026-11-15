# What is proven

A feature is listed as proven only if someone ran it and saw the result. All other items are in "Not proven".

## Nix images

Proven on 2026-11-13 on a single-node [kind](https://kind.sigs.k8s.io) cluster: Kubernetes v1.37.0, gVisor workers, a Debian node with Nix 2.35.6, and the two container images from this repository.
[../kind/README.md](../kind/README.md) has the steps to repeat it. `kind/prove.sh` and `kind/private-cache.sh` are the checks.

| Claim | Evidence |
| --- | --- |
| An actor boots from a store path. | A template with `nix:/nix/store/...-ate-proof-image` reached its golden snapshot. The actor answered HTTP through the Substrate router. |
| The actor sees its closure and nothing else. | 8 store paths inside the actor, exactly the output of `nix-store --query --requisites`. The node's store had 1861. |
| An actor cannot change the node's store or another actor's image. | The actor, as root, tried to append to a store file, replace it, and create a new store entry. The append was refused. The replace and the create succeeded in the actor's private layer only: the actor then read the changed file. On the node, the store file and the view were unchanged, `nix-store --verify-path` passed for the whole closure, and no new entry existed. A second actor from the same image read the original file and saw exactly the closure. `kind/prove.sh` checks this on each run. |
| A derivation is not an image. | The API refused a template with `nix:/nix/store/...-ate-proof-image.drv`: `names a derivation (.drv), not a built store path`. |
| Suspend and resume work. | A counter in the actor's writable layer continued after `kubectl ate suspend actor`. |
| The node downloads what it lacks. | Two paths that were not on the node (`darkhttpd`, `static-web-server`) came from `cache.nixos.org`, passed the signature check and booted in about 4 and 11 seconds. |
| A path that no cache has fails cleanly. | The template reports `GoldenActorCrashed ... no binary cache configured on this node has /nix/store/...`, then the Nix error `... there is no substituter that can build it`. The message does not mention signatures. |
| A private cache is used only for paths that a trusted key signed. | `kind/private-cache.sh` puts three new images into a local cache. The image signed with a key in the node's `trusted-public-keys` booted, and is in the node's store with that signature. The unsigned image and the image signed with an unknown key were refused, and each template's error gives the cause: `binary cache http://ate-nix-cache has /nix/store/..., but it carries no signature`, and `... signed only by keys this node does not trust: ate-rogue-1`. Neither reached the node's store. |
| An image can be revoked. | Same script. After the trusted key left the node, a new template from the image that the node already had still booted: a key removal alone changes nothing. `atelet --nix-revoke` then removed the view and the store path. The next template from that image was refused with `... signed only by keys this node does not trust: ate-proof-1`, and the path did not come back. In a second run, an environment that was running from a revoked image lost its programs (`go: command not found`) and did not resume after a suspend. |
| OCI images still work. | The upstream counter demo ran on the same patched atelet. |

Also proven, without a cluster: the Go unit tests of the patch pass, and the Nix build runs them. CI builds the packages and images, and runs those tests, on `x86_64-linux` and `aarch64-linux`.

### Not proven

- MicroVM workers. The test machine has no KVM.
- More than one node.
- Cleanup of views over time (the garbage collection pass). Unit tests cover the rules. No long-running cluster has exercised them.
- A cache that needs a login. The private cache in the test was plain HTTP without authentication.
- Store-write isolation with microVM workers. The test above used gVisor.
- The NixOS module `modules/ate-node.nix` on a real machine. CI evaluates it in a minimal NixOS configuration and checks the resulting `nix.conf` and bind mount. No NixOS node has run it.
- Revocation on more than one node, and of a path that many images share. The test revoked one image on one node.
- `aarch64-linux` on a cluster. CI builds it and runs the unit tests. No actor has run on an ARM node.
- The `aarch64-darwin` build.
- The full `cmd/atelet` test suite under Nix. It needs mount privileges that the Nix build sandbox does not have, so the build runs only the tests of the changed packages.

## Portable installer and node compatibility

Proven on `x86_64-linux` on 2026-11-14:

- The isolated portable-installer change passed all 14 root flake checks, including the full installer config, images, and steps test packages and real manifest rendering for Envoy and Agentgateway.
- The built `ate-setup` loaded a relative install document from a fresh directory outside the checkout with `PATH=/nonexistent`, selected `existingCluster.enabled=true`, and reached the expected missing-kubeconfig error. No Docker, Go, ko, or GCP executable was available; the nonexistent kubeconfig prevented cluster requests.

The compiled
`internal/imagecache` regression binary ran `TestLegacyOverlayMount` as root
inside a private mount namespace and passed. It invoked the legacy `mount(2)`
path directly, including its filesystem behavior checks. This verifies the
fallback implementation on the test host's kernel, not automatic fallback on
an older kernel or a complete worker deployment.

## Registry-free pod delivery

Proven on `x86_64-linux` on 2026-11-14:

- The registry-free PR's root flake checks passed, including the complete bundle, built image-reference validation, package tests, and node configuration checks.
- The Envoy dynamic module passed all 27 Rust tests and loaded successfully into the packaged Envoy for real listener and HTTP-filter configuration validation.
- The permanent `registry-free-node` VM check passed with a separate node store. The probe archive and file-backed dependency were absent before pulling; the signed cache served their closure, with a recorded archive `.narinfo` request. A real containerd CRI sandbox and container started using the Nix snapshotter. The container ran as UID 10001, resolved supplementary group 10002, read its file-backed store mount, and exited 0. An unsigned archive was refused and remained absent; snapshotter GC roots existed.

This is a signed-substitution/containerd runtime proof, not a complete fresh Substrate/Kubernetes installation. Kubernetes bootstrap, every bundled service's runtime behavior, ARM runtime, and production operation have not been qualified here. Snapshotter avoids conventional registry image publication but retains OCI metadata archives and small filesystem descriptors internally.

## PTY streams

- Proven: the Go tests of the patched env packages pass, the package builds, and the new flags are in `ate-env --help`.
- Proven on the kind cluster, with the env service in front of the reference project's agent image (a Nix image): a scripted session with `ate-env <id> shell --tty sh`. The remote side was a real terminal (`/dev/pts/0`) with the size of the local one (40x120), and it followed a resize to 30x100. `go test` ran in the session. Ctrl-C reached the remote shell and did not end it. `exit 3` returned exit code 3, and the local terminal had its first settings again afterwards. [../examples/reference/README.md](../examples/reference/README.md) has the steps.
- Proven on Linux on 2026-11-14: a throwaway smoke launched the built `ate-env` executable through a real local PTY against the real env API and guest, with a fake Substrate control plane and router. Both route-timeout and idle-timeout cuts at 300 ms preserved input sent after 1.2 seconds idle. The remote side reported `/dev/pts/1` and 40x120; both input lines returned, remote exit code 3 propagated, and the local terminal settings were restored. This is a transport/CLI smoke, not a Kubernetes deployment or model-inference proof.
- Not proven: `--suspend-on-osc-7501-inactive` against a cluster. A person at a real terminal emulator: the session above was driven by a script through a pseudo-terminal.


## OMP actor image

Proven on `x86_64-linux` on 2026-11-14:

- The isolated OMP change passed all 43 root flake checks and all 11 reference-project checks.
- `examples/omp/smoke-rootfs.sh` ran the built image in a fresh bubblewrap root with no host authentication/configuration and no network access. OMP reported `18.20.2`, its native `--smoke-test` returned `smoke-test: ok`, and the actual env guest answered `/readyz` after creating its writable workspace/session directories.
- An Expect-driven terminal rendered first-run provider setup and the main no-model UI, skipped optional setup without signing in, and exited successfully through `/quit`.

This proves the packaged binary/native dependencies, writable guest startup, and terminal rendering. The rootfs smoke exposes the whole read-only host store, so it is not a closure-isolation proof.

Proven on the kind cluster (`x86_64-linux`, gVisor) on 2026-11-15, with `main` at `72f453b`:

- The template `examples/omp/env-template.yaml.tmpl` with `nix:<.#omp-image>` reached its golden snapshot. The env service ran from the Nix-built `.#ate-env-api-image`.
- `ate-env create`, then `ate-env <id> shell 'pwd; omp --version; omp --smoke-test'` gave `/workspace`, `omp/18.20.2` and `smoke-test: ok`. The actor saw 158 store paths; the node had 9598.
- `examples/omp/smoke.exp` passed with `CUT_WAIT_SECONDS=20`: version, native smoke, PTY size 40x120, input after two idle periods in order, remote exit code 7, local terminal restored. 20 seconds is shorter than the router timeouts, so this run did not cut a stream.
- `ate-env <id> shell --tty omp`, driven by a script through a pseudo-terminal, showed the first-run setup, the main screen with `v18.20.2` and no model, and exited with code 0 through `/quit`.
- A file in `/workspace` was there after `ate-env suspend` and the next command.

Not proven: a model request (no provider credentials were used), stream recovery after a real router cut, certificate rotation, a person at a real terminal emulator, and ARM.

## Reference project

- Proven: `nix flake check` passes in `examples/reference` (app tests, both images, the image rules). On the kind cluster, the runtime image booted and served the app. The agent image booted, and a test client of its env guest daemon ran `go test` and `git` in it.
- Proven: the env service (`ate-env-api`) with the agent image as its template. `ate-env create`, `ate-env <id> shell` and `shell --tty` worked from the Nix-built `ate-env`, and the files in `/work` were there after `ate-env suspend` and the next command. See "PTY streams" above.
- The `ate-env-api` container image for that test was made by hand from the built binary. The flake output `.#ate-env-api-image` came later: it builds, and it ran as the env service in the OMP actor proof above.

## Review status

The Nix image patch is an independent implementation of an idea by Samuel Huber. He has not reviewed it, and neither have the Agent Substrate maintainers. No security review has been done.
