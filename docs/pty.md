# PTY streams (`ate-env`)

A real interactive terminal in a remote environment.
This feature is independent of Nix images. You can use one without the other.

## Background

`agent-substrate/env` is an upstream project that turns a Substrate actor into an "environment": you run commands in it and read and write its files. Its parts are:

- `ate-env`: the command-line tool on your machine.
- `ate-env-api`: the API server in the cluster.
- `ate-env-guest`: a small server inside each environment.

Upstream `ate-env <id> shell` runs a command and returns its output. It has no terminal, so a full-screen program (an editor, a coding agent's interface) does not work.

## What the patch adds

`patches/env/0001-pty-process-streams.patch`, written by Samuel Huber:

- `ate-env <id> shell --tty <command>` attaches your terminal to the remote command. Keys go in, raw bytes come out, and the remote terminal follows the size of your window.
- `--suspend-on-osc-7501-inactive` suspends the environment after the terminal session ends, if the program reported that it is idle. The program reports this with a terminal escape sequence, OSC 7501 with `active=false`. An idle agent then costs nothing until the next request.
- In the API: a `pty` flag and an initial size on the start-process request, a `TermSize` message, and a `ResizeProcess` call. The guest and the API server implement them.

## Build and use

```sh
nix build .#ate-env
./result/bin/ate-env --help
./result/bin/ate-env <environment id> shell --tty bash
```

All three binaries must come from this build: the tool, the API server and the guest speak the extended API together.
You need a cluster with Agent Substrate and the env service. The upstream README at <https://github.com/agent-substrate/env> describes that setup.

## Differences from the original patch

Samuel Huber published the patch as a [gist](https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96) against an older env commit (`281e860`). This repository carries it rebased onto env `56424de`.

One part is dropped. His patch added mutual TLS between `ate-env-api` and the Substrate router, with the flags `-router-client-cert`, `-router-client-key` and `-router-ca`. Upstream `56424de` has the same feature built in. Use the upstream flags:

```text
-atenet-credential-bundle=/run/substrate-router-client/credential-bundle.pem
-atenet-ca-file=/run/substrate-router-client/router-ca.pem
```

The gist's `deploy-omp-env-pty.sh` passes the old flag names. Change them before you use that script with this build.
All other parts of his patch are applied unchanged.

A second patch, `patches/env/0002-substrate-v1.0.0.patch`, changes only `go.mod` and `go.sum`. It moves env from a Substrate pre-release to Substrate v1.0.0. No source change was necessary.

## What is tested

- The Go tests of the patched packages pass. The Nix build runs them.
- `ate-env --help` from the build shows `--tty` and `--suspend-on-osc-7501-inactive`.
- **Not tested here:** a terminal session against a live cluster. The gist's README reports one on the author's cluster with the original patch.
