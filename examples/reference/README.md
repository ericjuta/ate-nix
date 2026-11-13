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

## Open a terminal in the agent image

The env service (`ate-env-api`) starts an environment from a template that you name, and that template can be a Nix image. So `ate-env <id> shell --tty` reaches the agent image with no change to env. On the same kind cluster:

1. Build the container image of the patched `ate-env-api` and push it to the kind registry. Keep the digest reference that `docker push` prints.

   ```sh
   docker load < "$(nix build --no-link --print-out-paths ../..#ate-env-api-image)"    # ate-nix/ate-env-api:<version>
   docker tag ate-nix/ate-env-api:<version> localhost:5001/ate-env-api
   docker push localhost:5001/ate-env-api
   ```
2. Deploy the env service. It reuses the worker image of the counter demo.

   ```sh
   ate-env manifest --replicas 2 --worker-image "$WORKER_IMAGE" \
     --api-image localhost:5001/ate-env-api@sha256:<digest> | kubectl --context kind-ate-nix apply -f -
   ```

3. Let the env service in. The Substrate router takes calls only from identities on its list, and the Substrate API takes them only from principals with a role. Add `spiffe://cluster.local/ns/ate-env/sa/default` to `--ingress-allowed-spiffe-ids` of the `atenet-router` Deployment in `ate-system`. Then:

   ```sh
   kubectl ate --context kind-ate-nix create atespace ate-env
   kubectl ate --context kind-ate-nix create access-policy -a ate-env -f examples/reference/kind/env-access-policy.yaml
   kubectl --context kind-ate-nix -n ate-env rollout restart deploy/ate-env-api
   ```

4. Register the agent image as the template that the env service uses by default, and connect:

   ```sh
   envsubst < examples/reference/kind/env-template.yaml.tmpl | kubectl ate --context kind-ate-nix create actor-template -f -
   kubectl --context kind-ate-nix port-forward -n ate-env svc/ate-env-api 7777:7777 &
   ate-env create dev1
   ate-env dev1 shell 'go version'
   ate-env dev1 shell --tty sh
   ```

On 2026-11-13 this ran with the `ate-env` binary from the Nix build. `ate-env dev1 shell` printed Go 1.27.3 and git 2.56.0 from `/work`. A scripted terminal session with `shell --tty sh` got `/dev/pts/0`. The remote terminal had the size of the local one (40x120) and followed a resize to 30x100. `go test ./...` passed in a new module. Ctrl-C did not end the shell. `exit 3` came back as exit code 3, and the local terminal had its first settings again. After `ate-env suspend dev1`, the next command woke the environment and the files in `/work` were there.

## Limits

- The agent cannot build Nix packages inside its actor. The actor has no Nix daemon and cannot change its image, by design. The agent edits code and runs `go test`. A separate job (CI) builds and signs the images.
- `ate-env manifest template` cannot write a template for a Nix image: it accepts OCI digest references only. Write the template yourself, as `kind/env-template.yaml.tmpl` does.
- `--suspend-on-osc-7501-inactive` has not run against a cluster.
- `aarch64-darwin` is not in `systems`: actor images are Linux.
