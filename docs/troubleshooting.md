# Troubleshooting

## Where to look

1. **The template status.** A template that cannot start its first actor reports `GoldenActorCrashed` with the error from atelet.
2. **The atelet log** on the node: `kubectl -n ate-system logs ds/atelet -c atelet`.
3. **The Nix daemon log** on the node: `journalctl -u nix-daemon`.

## Nix images

| What you see | Cause | What to do |
| --- | --- | --- |
| The API rejects a template with a `nix:` image when you create it. | The cluster runs the upstream `ateapi`, which requires an OCI digest. | Deploy the patched `ateapi`. See [operating.md](operating.md), step 2. |
| `nix image reference "...": want nix:/nix/store/<hash>-<name>` | The reference is not a store path directly under `/nix/store`. | Use the full store path of the image root, with its 32-character hash. Do not point at a file inside it. |
| `image "..." is a nix store path, but nix images are not enabled on this node (--nix-view-dir)` | atelet on that node runs without `--nix-view-dir`. | Apply the atelet arguments ([operating.md](operating.md), step 3), or send the template to a worker pool on nodes that have Nix. |
| `path '...' is required, but there is no substituter that can build it` | The node's Nix daemon did not accept the path from any cache. There are three causes with the same message: no configured cache has the path, the path is in a cache but unsigned, or its signature is from a key that the node does not trust. | Check that the closure is in your cache (`nix path-info --store <cache> <path>`). Check that the path is signed and that the key is in the node's `trusted-public-keys`. |
| A new cache or key in `nix.conf` has no effect. | The Nix daemon reads its configuration only when it starts. | Restart the daemon. `kind/node-setup.sh` does this when the configuration changes. |
| `nix-daemon does not answer` from `kind/node-setup.sh` | The daemon did not start, or `/nix` holds no standard Nix installation. A socket file can exist while no daemon runs. | Read `journalctl -u nix-daemon` on the node. |
| `... (the nix view dir must be on the same mount as the nix store)` | `--nix-view-dir` is on a different filesystem mount from `/nix/store`. Hard links cannot cross mounts. | Put the view directory under `/nix`, outside `/nix/store`, for example `/nix/var/ate/views`. |

## The local kind proof

| What you see | Cause | What to do |
| --- | --- | --- |
| The upstream install fails when it pushes an image to `localhost:5001` (connection refused). | Your default `docker buildx` builder uses the `docker-container` driver. It cannot reach the local registry. | `export BUILDX_BUILDER=default` and run the install again. |
| `kind/prove.sh` stops with `the proxy exited; is port 8017 taken?` | Another process uses the port. | Stop that process, or set `PORT` to a free port. |
| `kubectl ate proxy actor` fails with `no such host`. | The port argument has the wrong form. | Use `<local port>:<actor port>`, for example `kubectl ate proxy actor <name> 8017:80 -a <atespace>`. |
| A template seems to ignore your change. | Templates cannot be changed. | Create a template with a new name. |

## Builds

| What you see | Cause | What to do |
| --- | --- | --- |
| `hash mismatch in fixed-output derivation`, with `specified:` and `got:` | A pin changed and its hash did not. | See [maintaining.md](maintaining.md), "Update a pin". |
| Nix in the container refuses the checkout because another user owns it (git reports "dubious ownership"). | The container's user does not own the mounted checkout. | Use the `nixc` function from [getting-started.md](getting-started.md). It marks `/src` as safe for git. |
| A patch does not apply. | Upstream changed the same lines. | Rework the patch against the new commit. See [maintaining.md](maintaining.md), "Change a patch". Do not apply it with fuzz. |
| Nix does not see a new file. | A flake in a git repository sees only tracked files. | `git add` the file. |
