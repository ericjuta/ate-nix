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

## PTY streams

- Proven: the Go tests of the patched env packages pass, the package builds, and the new flags are in `ate-env --help`.
- Proven on the kind cluster, with the env service in front of the reference project's agent image (a Nix image): a scripted session with `ate-env <id> shell --tty sh`. The remote side was a real terminal (`/dev/pts/0`) with the size of the local one (40x120), and it followed a resize to 30x100. `go test` ran in the session. Ctrl-C reached the remote shell and did not end it. `exit 3` returned exit code 3, and the local terminal had its first settings again afterwards. [../examples/reference/README.md](../examples/reference/README.md) has the steps.
- Not proven: `--suspend-on-osc-7501-inactive` against a cluster. A person at a real terminal emulator: the session above was driven by a script through a pseudo-terminal.

## Reference project

- Proven: `nix flake check` passes in `examples/reference` (app tests, both images, the image rules). On the kind cluster, the runtime image booted and served the app. The agent image booted, and a test client of its env guest daemon ran `go test` and `git` in it.
- Proven: the env service (`ate-env-api`) with the agent image as its template. `ate-env create`, `ate-env <id> shell` and `shell --tty` worked from the Nix-built `ate-env`, and the files in `/work` were there after `ate-env suspend` and the next command. See "PTY streams" above.
- The `ate-env-api` container image for that test was made by hand from the built binary. The flake output `.#ate-env-api-image` came later: it builds, and it starts and prints its flags under Docker, but it has not run in a cluster.

## Review status

The Nix image patch is an independent implementation of an idea by Samuel Huber. He has not reviewed it, and neither have the Agent Substrate maintainers. No security review has been done.
