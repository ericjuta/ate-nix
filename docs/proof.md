# What is proven

A feature is listed as proven only if someone ran it and saw the result. All other items are in "Not proven".

## Nix images

Proven on 2026-11-13 on a single-node [kind](https://kind.sigs.k8s.io) cluster: Kubernetes v1.37.0, gVisor workers, a Debian node with Nix 2.35.6, and the two container images from this repository.
[../kind/README.md](../kind/README.md) has the steps to repeat it. `kind/prove.sh` and `kind/private-cache.sh` are the checks.

| Claim | Evidence |
| --- | --- |
| An actor boots from a store path. | A template with `nix:/nix/store/...-ate-proof-image` reached its golden snapshot. The actor answered HTTP through the Substrate router. |
| The actor sees its closure and nothing else. | 8 store paths inside the actor, exactly the output of `nix-store --query --requisites`. The node's store had 1861. |
| Suspend and resume work. | A counter in the actor's writable layer continued after `kubectl ate suspend actor`. |
| The node downloads what it lacks. | Two paths that were not on the node (`darkhttpd`, `static-web-server`) came from `cache.nixos.org`, passed the signature check and booted in about 4 and 11 seconds. |
| A path that no cache has fails cleanly. | The template reports `GoldenActorCrashed ... there is no substituter that can build it`. |
| A private cache is used only for paths that a trusted key signed. | `kind/private-cache.sh` puts three new images into a local cache. The image signed with a key in the node's `trusted-public-keys` booted, and is in the node's store with that signature. The unsigned image and the image signed with an unknown key were refused with the same `no substituter` error. Neither reached the node's store. |
| OCI images still work. | The upstream counter demo ran on the same patched atelet. |

Also proven, without a cluster: the Go unit tests of the patch pass, and the Nix build runs them.

### Not proven

- MicroVM workers. The test machine has no KVM.
- More than one node.
- Cleanup of views over time (the garbage collection pass). Unit tests cover the rules. No long-running cluster has exercised them.
- A cache that needs a login. The private cache in the test was plain HTTP without authentication.
- A direct test that an actor cannot change the node's store through its view. The design depends on the view being a read-only bottom layer.
- The NixOS module `modules/ate-node.nix`. It has not been evaluated on a NixOS machine.
- `aarch64-linux` and `aarch64-darwin` builds.
- The full `cmd/atelet` test suite under Nix. It needs mount privileges that the Nix build sandbox does not have, so the build runs only the tests of the changed packages.

## PTY streams

- Proven: the Go tests of the patched env packages pass, the package builds, and the new flags are in `ate-env --help`.
- Not proven here: an interactive session against a live cluster.

## Review status

The Nix image patch is an independent implementation of an idea by Samuel Huber. He has not reviewed it, and neither have the Agent Substrate maintainers. No security review has been done.
