# OMP in an Agent Substrate actor

This example installs the unmodified upstream [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) coding agent in a Nix-store image, together with the patched env guest. It starts the guest API, not an application server. Run OMP through `ate-env <id> shell --tty omp`.

There is no model proxy, organization configuration, injected provider catalog, credential, or custom OMP patch. Choose a provider and supply your own credentials at runtime.

## What is pinned

The root flake's `omp` input is OMP **18.20.2**, commit [`7c49c11aa5bbaf3f418406583096168ad5b8c6dc`](https://github.com/can1357/oh-my-pi/tree/7c49c11aa5bbaf3f418406583096168ad5b8c6dc), with source NAR hash `sha256-tDXp+gsI02YiwKwh+pZpbDMIgioWZdbAMmGCPCu57iw=`. Its own locked flake supplies Bun 1.4.4, Rust, bun2nix dependencies, the native addon, and Linux loader fixups. Do not replace it with a downloaded release binary or make its nixpkgs input follow this repository's: those are different packaging contracts.

`pkgs/omp-image.nix` accepts that package as its `omp` argument:

```nix
pkgs.callPackage ./pkgs/omp-image.nix {
  omp = inputs.omp.packages.${system}.omp;
}
```

The image uses this repository's existing `ateNixImage` builder and `nix:/nix/store/...` image format. It is not an OCI archive and is not a `nix:0...` reference. Build for the worker's Linux architecture, not the machine running your terminal.

The env package remains pinned to [`56424de763f91daa6b6c38f6249bacef1d82e5e1`](https://github.com/agent-substrate/env/tree/56424de763f91daa6b6c38f6249bacef1d82e5e1), with the existing dependency update to Substrate v1.0.0 plus PTY, router TLS rotation, and process-stream recovery patches. [PTY documentation](../../docs/pty.md) describes the patch order and behavior.

## Required cluster setup

Before creating an environment:

1. Install Agent Substrate and enable this repository's Nix-image support on the nodes serving the env worker pool. See [operating.md](../../docs/operating.md). The node daemon must trust a cache containing the complete signed OMP image closure.
2. Deploy **this build's** `ate-env-api`, not an unpatched upstream API image. Build `.#ate-env-api-image` and publish it to your registry; `ate-env manifest --api-image <digest-pinned-ref> --worker-image <your-worker-image>` generates the env deployment. The worker image and snapshot storage must already be configured for your cluster.
3. Authorize the env service account in Substrate and admit its identity to the router, following your cluster's authentication setup. The [reference example](../reference/README.md#open-a-terminal-in-the-agent-image) shows the required env atespace/access-policy steps. This example does not install or change cluster policy.
4. Ensure the env worker pool has the label `workload: ate-env`, runs on Nix-enabled nodes, and has capacity for this template's **2 CPUs and 4 GiB** per active actor. Adjust the template and pool together if necessary.
5. Permit DNS and outbound HTTPS to the model provider you select. Extra OMP tools may need their own network access or credentials. A working substrate terminal does not imply working provider authentication.

## Build, publish, and register

On a Linux builder of the worker's architecture, from the repository root:

```sh
nix build .#ate-env -o result-ate-env -L
export OMP_IMAGE=$(nix build .#omp-image -o result-omp-image --print-out-paths -L)
```

On macOS, build the image with your configured Linux remote builder or run these commands on a Linux build machine. The host `ate-env` CLI can be built for macOS separately.

Sign and publish `"$OMP_IMAGE"` and its complete closure to the node's trusted binary cache as described in [nix-images.md](../../docs/nix-images.md). A local build or an OMP upstream cache alone does not publish this repository's newly built image root and patched guest. No signing key belongs in the image.

Templates are immutable. Choose a fresh suffix for each image revision:

```sh
export TEMPLATE_SUFFIX=1
# envsubst is provided by gettext.
envsubst '${OMP_IMAGE} ${TEMPLATE_SUFFIX}' < examples/omp/env-template.yaml.tmpl \
  | kubectl ate create actor-template -f -
kubectl ate get actor-template "omp-$TEMPLATE_SUFFIX" -a ate-env -o yaml
```

Wait until the template has a `snapshotTime`; that means its guest answered `/readyz` and a golden snapshot exists. If it fails, inspect the template error before proceeding. This does **not** test an OMP model request.

In another terminal, keep the env API port-forward open:

```sh
kubectl -n ate-env port-forward svc/ate-env-api 7777:7777
```

Then create the environment and inspect the actual executable:

```sh
export PATH="$PWD/result-ate-env/bin:$PATH"
export SUBSTRATE_ENV_API=127.0.0.1:7777
ate-env create omp-dev --template "omp-$TEMPLATE_SUFFIX"
ate-env omp-dev shell 'pwd; omp --version; omp --smoke-test'
ate-env omp-dev shell --tty --timeout 24h omp
```

Expected noninteractive results are workspace `/workspace`, version `18.20.2`, and `smoke-test: ok`. These are checks to run, not a claim that this example has already passed on your cluster. `--tty` requires a real local terminal; redirecting stdin from `/dev/null` is not an interactive smoke.

## Your credentials and workspace

The actor starts with writable `/workspace` as HOME and working directory. OMP sessions use `/workspace/.omp/sessions`; OMP owns its normal settings/authentication files under that HOME. Nothing from your host HOME is mounted or copied automatically.

In OMP, use `/login` to configure a provider with your own supported API key or OAuth flow, then select your model with `/model`. A remote/headless actor may require a provider's manual browser/callback flow. Alternatively, start `ate-env omp-dev shell --tty --timeout 24h bash`, set your provider's documented API-key environment variable **inside that remote shell**, and run `omp`. Local shell environment variables are not automatically forwarded by `ate-env`.

Do not put secrets into Nix expressions, the flake, template YAML, image `Env`, command-line arguments, or committed files. Do not use `ate-env ... write` to upload a secret without checking and restricting its remote file permissions. OMP may save credentials in the actor, and memory/disk snapshots may contain them. Protect snapshot storage and access to the env API accordingly; deleting a local credential does not erase earlier snapshots.

The image supplies Bash, Git, SSH, core Unix tools, curl, jq, Node.js, and Python. OMP itself includes its compiled Bun runtime and native addon. This is not a general Linux distribution: it has no package manager, Nix daemon, browser, language toolchains beyond those listed, or desktop/audio services. Add project-specific tooling to the image's package list and rebuild rather than trying to modify `/nix/store`.

The guest has an upstream default **one-hour process timeout**. The examples explicitly request `--timeout 24h` for long OMP sessions. Stream recovery does not remove process timeouts or output-spool limits. Exit OMP before `ate-env suspend omp-dev` unless you deliberately want its running process checkpointed; the next env request wakes a suspended actor. `ate-env delete omp-dev` removes that environment through the env service.

## Smoke checks

The upstream OMP derivation runs `--smoke-test` and native-library checks during its build. Those are not a substitute for launching it in an actor with this root filesystem.

For a cluster-free Linux runtime check, use the image's actual config and a fresh root/HOME:

```sh
nix shell nixpkgs#bubblewrap nixpkgs#jq \
  -c ./examples/omp/smoke-rootfs.sh "$OMP_IMAGE"
# In a real terminal, or driven by Expect, launch the actual UI:
nix shell nixpkgs#bubblewrap nixpkgs#jq \
  -c ./examples/omp/smoke-rootfs.sh "$OMP_IMAGE" --tui
```

This requires Linux with working user namespaces. The default check runs the installed OMP version/native smoke, starts the image's real guest entrypoint, waits for `/readyz`, and checks initialization of writable state. `--tui` runs OMP interactively without extensions or saved sessions. Both use an empty temporary HOME, import no host credentials, and isolate networking; they cannot test inference. Confirm the UI renders/responds and exit it normally. The script exposes the host's read-only Nix store to satisfy loader paths, so it is not a closure-isolation proof or a security sandbox audit. It does not substitute for the live env API/PTY check below.

After the environment exists, the executable Expect script checks the installed OMP version/native smoke, PTY input after two idle periods, output ordering, remote exit code 7, and restoration of the local terminal:

```sh
# Install/use Expect on the machine running the CLI.
# Set this longer than the router timeout being tested, in seconds.
ATE_ENV_BIN="$PWD/result-ate-env/bin/ate-env" CUT_WAIT_SECONDS=200 \
  expect examples/omp/smoke.exp omp-dev
```

Use the timeout values actually configured on **your** router; 200 is only an example. Run once with a finite route timeout, then separately with the route timeout disabled or longer than the stream-idle timeout to exercise an idle cut. Waiting longer cannot exercise idle timeout if a shorter route timeout always wins. The Go regression tests deterministically cover both response classes without changing cluster settings.

For end-to-end provider verification, launch the interactive command above, authenticate, and ask OMP to create and read back a small file under `/workspace`. Confirm the selected model actually answers and the file exists with `ate-env omp-dev shell 'cat <file>'`. This makes a real provider request and may incur cost; the Expect script intentionally does not do it.

Reconnection limitations and certificate rotation are documented in [pty.md](../../docs/pty.md#stream-recovery). None of the new image, stream-cut, certificate-rotation, or model-provider checks are claimed as exercised by this example's documentation.
