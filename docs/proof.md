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
| OCI images still work. | The upstream counter demo ran on the same patched atelet. |

Also proven, without a cluster: the Go unit tests of the patch pass, and the Nix build runs them. CI builds the packages and images, and runs those tests, on `x86_64-linux` and `aarch64-linux`.

### Not proven

- MicroVM workers. The test machine has no KVM.
- More than one node.
- Cleanup of views over time (the garbage collection pass). Unit tests cover the rules. No long-running cluster has exercised them.
- A cache that needs a login. The private cache in the test was plain HTTP without authentication.
- Store-write isolation with microVM workers. The test above used gVisor.
- The NixOS module `modules/ate-node.nix` on a real machine. CI evaluates it in a minimal NixOS configuration and checks the resulting `nix.conf` and bind mount. No NixOS node has run it.
- Revocation. A view that exists is used again without a new signature check, so the removal of a trusted key does not stop an image that the node already has.
- `aarch64-linux` on a cluster. CI builds it and runs the unit tests. No actor has run on an ARM node.
- The `aarch64-darwin` build.
- The full `cmd/atelet` test suite under Nix. It needs mount privileges that the Nix build sandbox does not have, so the build runs only the tests of the changed packages.

## PTY streams

- Proven: the Go tests of the patched env packages pass, the package builds, and the new flags are in `ate-env --help`.
- Not proven here: an interactive session against a live cluster. This includes the change that restores the terminal before a failed command's exit code is returned: a unit test covers the exit code, and nothing has exercised the terminal.

## Reference project

- Proven: `nix flake check` passes in `examples/reference` (app tests, both images, the image rules). On the kind cluster, the runtime image booted and served the app. The agent image booted, and a test client of its env guest daemon ran `go test` and `git` in it.
- Proven on the guest side only: a command started in terminal mode in that actor got a pseudo-terminal (`/dev/pts/0`, 24x80) and its exit code came back. This used the patched guest daemon, not the `ate-env` command-line tool.
- Not proven: the env service (`ate-env-api`, `ate-env <id> shell`) with the agent image. The agent image has run only as a plain Substrate actor.

## Review status

The Nix image patch is an independent implementation of an idea by Samuel Huber. He has not reviewed it, and neither have the Agent Substrate maintainers. No security review has been done.
