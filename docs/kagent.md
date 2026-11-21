# kagent agents from Nix images

[kagent](https://kagent.dev) is an agent framework for Kubernetes. You describe an agent as a Kubernetes resource (`Agent`), and since version 1.0 kagent runs each agent session as an Agent Substrate actor.
This page shows a kagent agent whose filesystem is a Nix store path instead of a container image.

It is a proof on a local throwaway cluster, not a supported integration. [Read what was seen and what was not](#what-was-seen) before you rely on it.

## How the pieces fit

kagent does not use upstream Substrate. It installs its own fork, [`kagent-dev/substrate`](https://github.com/kagent-dev/substrate). kagent `v1.0.1` installs fork release `v1.0.0`.
Three things are in the way of a Nix image, and this repository has a part for each:

| In the way | Part of this repository |
| --- | --- |
| The fork's atelet and ateapi know only OCI images. | `.#kagent-atelet-image` and `.#kagent-ateapi-image`: the fork at `v1.0.0` with the same four `patches/substrate` files that `.#ate-substrate` uses. They apply to the fork unchanged. |
| kagent itself refuses an image that is not an OCI reference pinned by digest. It checks in its controller and in three resource definitions (CRDs). | `patches/kagent/0001-accept-nix-store-path-images.patch`, built into `.#kagent-controller-image`. `kind/kagent.sh` puts the same pattern into the installed CRDs. |
| kagent's agent runtime (the program that runs inside the actor and talks to the model) comes as an OCI image. | `.#kagent-adk-image`: the runtime built from the same patched source, as a Nix image. |

Words used below, in kagent's meaning:

| Term | Meaning |
| --- | --- |
| **Agent** | The resource that describes one agent: its model, its prompt and its harness. |
| **Harness** | The resource that says which runtime image an Agent runs in, and on which Substrate worker pool. kagent installs `kagent-default` with its stock OCI image. |
| **ModelConfig** | The resource that names a model provider, a model and the Secret with the API key. |
| **Session** | One conversation with an Agent. Each session is one Substrate actor, so it is suspended when idle and resumed on the next message. |

## Run it on kind

Needs what [../kind/README.md](../kind/README.md) needs (Docker, Go, `kubectl`, `git`, `envsubst`, `curl`), and also `jq`, [`helm`](https://helm.sh) and an API key for a model provider that kagent supports. `x86_64` Linux only: nothing else was tried.

The steps use this repository (`$ATE_NIX`) and a checkout of kagent's Substrate fork (`$SUBSTRATE`). Each step says where to run. Use one shell for all steps.

All `nix` commands run in a container, as in the other pages:

```sh
nixc() { docker run --rm -v ate-nix-store:/nix -v "$PWD:/src" -w /src nixos/nix:latest \
  sh -c 'git config --global --add safe.directory /src; nix --extra-experimental-features "nix-command flakes" "$@"' nix "$@"; }
```

### 1. Build

In this repository:

```sh
export ATE_NIX="$PWD" OUT=/tmp/ate-nix-kagent-out
mkdir -p "$OUT/bin"
nixc build --no-link --print-out-paths .#kagent-adk-image .#kagent-controller-image \
  .#kagent-atelet-image .#kagent-ateapi-image | tee "$OUT/paths"
for p in $(grep -e '\.tar\.gz$' "$OUT/paths"); do
  docker run --rm --user "$(id -u)" -v ate-nix-store:/nix -v "$OUT:/out" busybox cp -L "$p" /out/
done
export KAGENT_ADK_IMAGE="$(grep -e '-kagent-adk-nix-image$' "$OUT/paths")"
ls "$OUT"; echo "$KAGENT_ADK_IMAGE"
```

Three container image tarballs are now in `$OUT`. The fourth result, the agent runtime, stays in the Nix store: that is the point.

### 2. Cluster and stock kagent

Get the fork at the release that kagent `v1.0.1` installs, and create the cluster with the Nix store mounted into its node:

```sh
export SUBSTRATE=/tmp/ate-nix-kagent-substrate
git clone --branch v1.0.0 --depth 1 https://github.com/kagent-dev/substrate "$SUBSTRATE"
cd "$SUBSTRATE"
git apply "$ATE_NIX/kind/create-kind-cluster.patch"
export KIND_CLUSTER_NAME=ate-nix ATE_INSTALL_KIND=true BUILDX_BUILDER=default
hack/create-kind-cluster.sh
kubectl config use-context kind-ate-nix
```

Install kagent with its own command-line tool. It installs the fork's Substrate, a database, kagent and a worker pool:

```sh
curl -fsSL -o "$OUT/bin/kagent" https://github.com/kagent-dev/kagent/releases/download/v1.0.1/kagent-linux-amd64
chmod +x "$OUT/bin/kagent"
export PATH="$OUT/bin:$PATH"
OPENAI_API_KEY=<your key> kagent install --provider OpenAI --timeout 15m
```

This creates a ModelConfig named `default-model-config`. To use another provider, see `kagent install --help`.

### 3. Switch to the patched parts

In this repository:

```sh
cd "$ATE_NIX"
kind/kagent.sh
```

The script loads the three tarballs into the node, configures Nix on the node (`kind/node-setup.sh`), switches atelet, ateapi and the kagent controller to the patched images, and changes the image pattern in the three installed CRDs. Its last line is `DONE`.

### 4. An Agent on a Nix image

```sh
export MODEL_CONFIG=default-model-config
envsubst < kind/kagent-agents.yaml.tmpl | kubectl apply -f -
kubectl -n kagent wait agent/assistant-nix agent/assistant-oci --for=condition=Ready --timeout=5m
kubectl -n kagent get agents -o custom-columns=NAME:.metadata.name,IMAGE:.status.workloadImage
```

`assistant-nix` uses the new Harness `kagent-nix`, whose image is `nix:$KAGENT_ADK_IMAGE`. `assistant-oci` is the same agent on kagent's stock harness, to compare with.
`Ready` means that Substrate booted the runtime from the image and took its golden snapshot. It does not show that the model answers. The next step does.

### 5. Talk to it

```sh
kubectl -n kagent port-forward svc/kagent-controller 8083:8083 >/dev/null 2>&1 &
sleep 3
SESSION=$(kagent agent session create --agent assistant-nix -o json | jq -r .session.id)
kagent agent invoke --session "$SESSION" --task "Reply with the single word: pong"
kagent agent invoke --session "$SESSION" --task 'Call your bash tool once with this command and reply with only its raw output: readlink -f /bin/bash; ls /nix/store | wc -l'
```

The first answer shows that the runtime reached the model. The second shows where the agent runs: kagent's runtime gives every agent a `bash` tool, and here that shell is a store path and sees only the closure of the image.
Ask for the tool call in so many words. An agent that is only asked where `/bin/bash` is answers from the model's memory, with a different guess on each run.

Then see the session suspend and resume. kagent suspends an idle session after about a minute:

```sh
(cd "$SUBSTRATE" && go build -o "$OUT/bin/kubectl-ate" ./cmd/kubectl-ate)   # kubectl finds it as `kubectl ate`
until kubectl ate get actor -a kagent 2>/dev/null | grep "$SESSION" | grep -q ACTOR_STATE_SUSPENDED; do sleep 5; done
kagent agent invoke --session "$SESSION" --task "What was the first word of your previous reply?"
```

The answer comes from an actor that Substrate restored from its snapshot.

### Teardown

```sh
kill %1                                              # the port-forward
(cd "$SUBSTRATE" && KIND_CLUSTER_NAME=ate-nix hack/delete-kind-cluster.sh)
docker volume rm ate-nix-store
rm -rf "$OUT" "$SUBSTRATE"
```

## What was seen

Seen on 2026-11-21 on one machine: `x86_64` Linux, a single-node kind cluster, Kubernetes v1.37.0, gVisor workers, kagent `v1.0.1` on its Substrate fork `v1.0.0`. The steps above were run as written, with the four results of step 1. One thing differed: the model was `gpt-6-luna` behind a local OpenAI-compatible gateway, through a ModelConfig with a `baseUrl`, not `default-model-config`. Steps 1 to 4 took under 5 minutes with the Nix store and the Docker images already on the machine. Nobody has timed a first run.

| Claim | Evidence |
| --- | --- |
| A kagent Agent boots from a store path. | `assistant-nix` became `Ready` with `status.workloadImage` `nix:/nix/store/plmidxpanzskg6a2q01xfdszrany1b1q-kagent-adk-nix-image`. `assistant-oci` became `Ready` on the same patched Substrate with kagent's stock image. |
| The whole patched stack comes from this repository. | The cluster ran `ate-nix/kagent-atelet:1.0.0`, `ate-nix/kagent-ateapi:1.0.0` and `ate-nix/kagent-controller:1.0.1`, all built by the flake. |
| The agent reaches a real model. | The Nix-booted agent answered `pong`. So did the OCI agent. |
| The agent's tools run inside the Nix image. | Asked to run `readlink -f /bin/bash`, `id -u` and a count of the entries of `/nix/store` with its `bash` tool, the Nix-booted agent returned `/nix/store/lfm00fnq66xfgbn099vqckabyl5jllz6-bash-interactive-5.3p20/bin/bash`, `65532` and `23`. The OCI agent returned `/bin/bash`, `65532` and `0`. Both wrote a file under `/tmp` and read it back. |
| The agent sees its closure and nothing else. | `23` is the size of the closure of the image (`nix-store --query --requisites`). The node's store had 3052 paths. |
| Suspend and resume work. | The session's actor reached `ACTOR_STATE_SUSPENDED` within a minute of its answer. The next message got `pong` as "the first word of your previous reply". |

Without a tool call, the answers about `/bin/bash` say nothing about the image. Asked "which directory does /bin/bash resolve to, else say unknown" three times each, the Nix-booted agent said `/usr/bin/bash` each time, which is wrong for its image, and the OCI agent said `/bin`, `/bin/bash` and `/usr/bin/bash`. An earlier run got `unknown` from the Nix-booted agent. These are guesses of the model.

### Not seen

- A kagent `SandboxTemplate` on a Nix image. The patch lets the reference through; nobody started one.
- The Claude and Codex harnesses of kagent, and a bring-your-own harness. Only the `kagent` harness type ran.
- Agents with MCP tools, skills or other agents as tools. The agents above had a model, a prompt and the built-in tools.
- kagent's `main` branch, which has moved to fork release `v1.1.0-alpha1`.
- The store-write checks of `kind/prove.sh` under kagent. That script cannot reach an actor on this cluster ([see below](#things-that-fail-and-why)).
- A Nix image that the node has to download. The image was built into the store that the node mounts.
- `default-model-config` with a provider's public API. The steps describe it; the run used the gateway.
- `aarch64`, microVM workers, more than one node, and a cluster that is not kind. CI builds the packages for `aarch64-linux`.
- A kagent upgrade or a Helm upgrade after step 3. Helm would put the stock images and CRD patterns back.

Nothing here has been proposed to kagent.

## Things that fail, and why

| You see | Cause |
| --- | --- |
| `kagent-controller` restarts with `built-in Harness images release "1.0.1" does not match controller release "dev"` | A controller built without its version stamp. `pkgs/kagent.nix` sets it. |
| The template of the Agent reports `GoldenActorCrashed ... :8081/readyz: connection refused`, and the worker log has `mkdir /config: permission denied` | The Harness lacks `args: ["--filepath=/tmp/config"]`. The runtime writes its agent configuration to `/config` by default. kagent's OCI image has that directory, owned by the runtime's user. The root of a store-path image belongs to root, and the runtime does not run as root. |
| The Agent is `Ready`, and its status never shows `workloadImage` | The `agents` CRD still has the old pattern. `kind/kagent.sh` changes three CRDs: `harnesses`, `sandboxtemplates` and `agents`. |
| An Agent reports `Compatible=False ... invalid egress origin "http://172.18.0.2:2455": expected a DNS name` | The `baseUrl` of the ModelConfig is an IP address. kagent wants a DNS name. For a model gateway on your own machine, create a Kubernetes Service without a selector and an EndpointSlice with the address, and use the Service's name. |
| `kind/prove.sh` fails with `the actor did not answer` on this cluster | kagent's Substrate router accepts only the kagent controller's identity, so `kubectl ate proxy` is refused. Use the kagent CLI as in step 5. |
