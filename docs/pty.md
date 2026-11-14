# PTY streams and long-lived sessions (`ate-env`)

A real interactive terminal in a remote environment. PTY streams are independent of Nix images; you can use either feature without the other. For a complete OMP image and launch instructions, see [examples/omp](../examples/omp/README.md).

## Background

`agent-substrate/env` turns a Substrate actor into an environment: you run commands in it and read and write its files. Its parts are:

- `ate-env`: the command-line tool on your machine.
- `ate-env-api`: the API server in the cluster.
- `ate-env-guest`: the small server inside each environment.

Upstream `ate-env <id> shell` runs a command and returns its output. It has no terminal, so a full-screen program such as an editor or coding agent cannot work normally.

## Patches and attribution

The package applies these patches in order to env `56424de763f91daa6b6c38f6249bacef1d82e5e1`:

| Patch | Purpose |
| --- | --- |
| `0001-pty-process-streams.patch` | Samuel Huber's PTY extension, rebased with ate-nix's terminal-restoration fix. |
| `0002-substrate-v1.0.0.patch` | The existing `go.mod`/`go.sum` update to Substrate v1.0.0. |
| `0003-free-slot-before-exit.patch` | The guest frees a process slot before it reports the exit. |
| `0004-router-tls-rotation.patch` | Samuel Huber's generic client-certificate and router trust-bundle rotation changes and tests. |
| `0005-resume-cut-process-streams.patch` | Samuel Huber's generic process-stream recovery changes and tests, adapted to retain ate-nix's exit-code handling. |

No deployment, model provider, organization configuration, or credentials are included in these patches.

### Interactive terminal

The PTY extension adds:

- `ate-env <id> shell --tty <command>`: keys go in, raw terminal bytes come out, and the remote terminal follows the size of your window.
- `--suspend-on-osc-7501-inactive`: after the terminal session ends, suspend the environment if the program reported that it was idle with OSC 7501 `active=false`.
- A `pty` flag and initial size on the process-start request, a `TermSize` message, and a `ResizeProcess` RPC in the guest, API server, and Go client.

Samuel Huber published the original PTY patch as a [gist](https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96) against env `281e860`. This repository carries it rebased onto `56424de`.

The gist's additional router-mTLS implementation is not needed: env `56424de` already has that feature. Use the upstream flags below rather than the gist's old `-router-client-cert`, `-router-client-key`, and `-router-ca` flags.

The original PTY patch called `os.Exit` inside the session, skipping deferred terminal restoration on non-zero remote exit. ate-nix instead returns an exit-code error and exits only after cleanup. That behavior and its existing `TestExitStatus` regression test are retained. Stream recovery now reads output synchronously through the process-exit message before returning; it replaces the previous parallel `Wait` and two-second output-drain loop, without reintroducing an early `os.Exit`.

## Build and use

```sh
nix build .#ate-env -L
./result/bin/ate-env --help
./result/bin/ate-env <environment-id> shell --tty bash
# The guest's default process timeout is one hour; request a longer limit:
./result/bin/ate-env <environment-id> shell --tty --timeout 24h omp
```

`--tty` requires stdin to be a real terminal. All three binaries must come from this build: the CLI, API server, and guest speak the extended API together. Deploying only a new local CLI does not replace the cluster API or the guest in an existing actor/template. Build a new guest image/template and use the patched API image too.

You need a cluster with Agent Substrate, a worker pool with snapshot storage, the env service, and the cluster's normal env-service authorization/router identity admission. The upstream [env README](https://github.com/agent-substrate/env) and the [reference example](../examples/reference/README.md) describe setup. The OMP example does not replace those prerequisites.

## Stream recovery

A process can outlive the gRPC stream carrying its output or stdin. Routers may impose a finite request/route timeout or a stream-idle timeout; a network interruption, router rollout, or interrupted port-forward can also cut streams.

Patch `0005` provides:

- Go client `Process.Follow`, `Process.Wait`, and `Env.Run` reconnect after `Unavailable`, `Internal`, or `Unknown` transport errors. `Unknown` includes Envoy's HTTP 408 stream-idle timeout without a gRPC status. Typed guest errors such as `NotFound` or `InvalidArgument` remain final.
- Output reopens at separate stdout/stderr byte offsets already delivered. The same client invocation does not intentionally replay those bytes. A caller's output-handler error is returned, not retried.
- Reconnect probes use `FindProcess`, with at most five attempts and backoff from 200 ms up to two seconds. Repeated fast output-stream failures without progress are bounded too. Context cancellation still stops the operation.
- A cut stdin stream is reopened when the next write reports the cut. The API watches the guest-side stream even while the caller is idle, so an upstream idle cut is propagated instead of waiting to consume and lose the next keystroke.
- `shell --tty` uses the resumable output path and still restores the local terminal before returning a remote non-zero exit code.

This is recovery **within a running client invocation**, not a new attach protocol. If `ate-env` itself exits, its port-forward remains unavailable until retries are exhausted, or the process/actor is deleted, the patch does not resurrect that terminal session. OMP's saved sessions are separate from transport reconnection.

The low-level `Process.Output` stream is still a single raw stream; callers wanting the reconnect loop should use `Follow` or `Wait`. File transfers and unrelated RPCs do not gain generic retries. A resize returning `Unavailable` is dropped; the next `SIGWINCH` supplies the current size.

Stdin is a stream, not a durable command-acknowledgement protocol. Do not interpret transport retries as an exactly-once guarantee for arbitrary network failures or application side effects. Output replay also depends on the guest retaining its spool: upstream defaults include a 10 MiB output cap, one-hour retention after process completion, and a one-hour default process timeout. Request a suitable `--timeout` for long sessions; reconnecting does not remove these limits.

For live route/idle-cut checks, use [examples/omp/smoke.exp](../examples/omp/smoke.exp) and its instructions. Exercise the two router configurations separately: a shorter route timeout otherwise prevents the stream-idle timeout from occurring. Do not assume a particular cluster's timeout values are upstream defaults.

## Router certificate and CA rotation

`ate-env-api` connects to the Substrate router using the upstream flags:

```text
-atenet-credential-bundle=/run/substrate-router-client/credential-bundle.pem
-atenet-ca-file=/run/substrate-router-client/router-ca.pem
```

These are example mount paths, not files created by this repository. Your cluster must issue the authorized client identity and mount its credential bundle plus the router CA trust bundle. Kubernetes projected pod certificates and cluster trust bundles can update the contents at these stable paths.

Upstream already reloads the client credential bundle on a new TLS handshake, but loads the router CA only at startup. Patch `0004` reloads **both** files on each new handshake, caching parsed material while the file bytes are unchanged. A long-lived API process can therefore present a rotated client certificate and trust a rotated router CA without a restart. Existing established connections are not forcibly replaced or reverified by a file change.

The patch moves server verification into `VerifyConnection` so it can use the current trust bundle. Although the TLS config uses `InsecureSkipVerify` to disable the fixed-root verification path, the custom verifier still requires a valid X.509 chain, validity dates, the upstream router DNS name `atenet-router.ate-system.svc`, and server-auth extended key usage. Untrusted, misnamed, and client-only serving certificates are rejected. Unreadable or malformed files fail credential initialization or the subsequent handshake; the code does not silently keep using a stale trust bundle.

This concerns the API-to-router connection. It neither provisions router certificates nor configures OMP's model-provider credentials or HTTPS trust. Coordinate CA rollover overlap and retirement in your cluster's certificate issuer/trust-bundle configuration.

## Verification scope and status

`pkgs/ate-env.nix` uses the buildGoModule check phase for these packages, not only the CLI binaries:

```text
cmd/ate-env
cmd/ate-env-api
cmd/ate-env-guest
guest/process
internal/apiservice
internal/ate
clients/go
```

The imported regression tests include `TestRouterTLSCredentialsFollowsRotatedCertificateAndTrustBundle`, `TestRouterTLSCredentialsRejectsUntrustedOrMisnamedRouter`, and `TestProcessStreamsSurviveRouterCuts` (route-timeout and stream-idle-timeout subtests). The latter checks input after idle cuts and exactly-once delivery of its expected output. The patch also isolates guest test spool directories so concurrently tested packages do not delete each other's output.

For a patched env source checkout, focused commands are:

```sh
go test ./internal/ate -run TestRouterTLSCredentials -count=1 -v
go test ./clients/go -run TestProcessStreamsSurviveRouterCuts -count=1 -v
go test ./cmd/ate-env -run TestExitStatus -count=1 -v
```

These commands run in the **patched env checkout**, not this Nix repository. `nix build .#ate-env -L` applies the full patch stack and runs the complete package scope above.

The earlier PTY implementation was exercised against a live kind cluster on 2026-11-13 for initial terminal size, resize, Ctrl-C, non-zero exit code, and local terminal restoration; [proof.md](proof.md) records that historical result. It does not prove the newly imported TLS/reconnect changes or the OMP image. No new build, stream-cut smoke, live certificate rotation, OMP TUI/model request, or `--suspend-on-osc-7501-inactive` result is asserted here.
