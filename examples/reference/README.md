# Reference project

A small project that uses ate-nix the way a real one would. One `flake.lock` fixes every version, and one `project.nix` gives four things:

| Output | What it is | Command |
| --- | --- | --- |
| `devShells.default` | The tools a person works with: Go, git, a shell, and the patched `ate-env` | `nix develop` |
| `packages.app` | The service, a small Go HTTP server in `app/` | `nix build .#app` |
| `packages.agent-image` | The actor image an agent works in: the same tools as the dev shell, plus the env guest daemon with a `/work` workspace | `nix build .#agent-image` |
| `packages.runtime-image` | The actor image that ships: the app and nothing else | `nix build .#runtime-image` |
| `checks` | The gates: tests, both images, and the rules below | `nix flake check` |

Read [../../docs/concepts.md](../../docs/concepts.md) first if "actor image" or "store path" are new words.

## Why this shape

- **One tool list.** `tools` in `project.nix` feeds the dev shell and the agent image. A person and an agent run the same Go at the same version. Change the list once and both change.
- **A patch reaches every consumer.** The flake takes `ate-nix` as its one input and follows its `nixpkgs`. When ate-nix changes a patch, `nix flake update ate-nix` here rebuilds the dev shell and the agent image with it. Nothing is copied by hand.
- **The checks are the gate.** `nix flake check` passes or fails as a whole. It is what CI runs for this directory.

## The checks

| Check | Fails when |
| --- | --- |
| `app` | The app does not compile or a Go test fails |
| `app-serves` | The built binary does not answer an HTTP request |
| `agent-image`, `runtime-image` | An image does not build |
| `agent-image-entrypoint`, `runtime-image-entrypoint` | The image configuration names a program that is not in the image |
| `runtime-image-has-no-toolchain` | Go or git got into the closure of the runtime image |

## Use it for your own project

1. Copy this directory.
2. In `flake.nix`, change the input to the published flake: `inputs.ate-nix.url = "github:<owner>/ate-nix";`. Run `nix flake lock`.
3. Replace `app/` and the `app` definition in `project.nix`. Edit `tools`.
4. Build the two images in CI, sign them, and push them to your binary cache. [../../docs/nix-images.md](../../docs/nix-images.md) shows the commands. Put the store paths that `nix build --print-out-paths` prints into your actor templates.

## Run both images on the kind cluster

With the cluster from [../../kind/README.md](../../kind/README.md) running and `kind/prove.sh` passed once (it creates the worker pool and the atespace):

```sh
export RUNTIME_IMAGE=$(nixc build --no-link --print-out-paths ./examples/reference#runtime-image)
export AGENT_IMAGE=$(nixc build --no-link --print-out-paths ./examples/reference#agent-image)
export SUFFIX=-1      # templates cannot be changed; use a new suffix for each try
envsubst < examples/reference/kind/templates.yaml.tmpl > /tmp/templates.yaml
# Create each of the two documents:
kubectl ate --context kind-ate-nix create actor-template -f <one document>
```

Each template is ready when `kubectl ate get actor-template <name> -a ate-nix-proof -o yaml` shows a `snapshotTime`. That means the image booted and answered its probe.

On 2026-11-13 both booted this way. The runtime actor answered `{"service":"reference-app","path":"/orders/7"}`. In the agent actor, a client of the guest daemon's process API created a Go module under `/work`, and `go test ./...` passed with the image's Go 1.27.3; `git` worked; a command started in terminal mode got `/dev/pts/0` at 24x80 and returned its exit code 3. The runtime image's closure is 10 MB and the agent image's is 705 MB.

## Limits

- The agent cannot build Nix packages inside its actor. The actor has no Nix daemon and cannot change its image, by design. The agent edits code and runs `go test`. A separate job (CI) builds and signs the images.
- The agent image has run as a plain Substrate actor, with a test client that talked to the guest daemon directly. Nobody has run the env service (`ate-env-api`) with a `nix:` guest image, so `ate-env <id> shell` against this image is untested. The env code requires an OCI digest only when the guest is mounted into a second image.
- `aarch64-darwin` is not in `systems`: actor images are Linux.
