# ate-nix

Agent Substrate `env` ([ate.dev](https://ate.dev)) with Sam Huber's PTY patch stack, packaged as a Nix overlay.
No fork, no cloned tree: upstream is pinned by hash and the changes live here as patch files.

## What you get

`nix build .#ate-env` produces `ate-env`, `ate-env-api` and `ate-env-guest` with:

- `ate-env <id> shell --tty <cmdline>`: a real remote PTY (raw byte stream, stdin, resize on SIGWINCH).
- `--suspend-on-osc-7501-inactive`: suspend the env actor after the PTY exits, if the program reported OSC 7501 inactive.
- `StartProcessRequest.pty` / `initial_size`, `TermSize` and the `ResizeProcess` RPC in the env API and guest.

## Pins

| What | Pin |
| --- | --- |
| `agent-substrate/env` | `56424de763f91daa6b6c38f6249bacef1d82e5e1` (main, 2026-11-01; no tag exists after `v0.0.10`) |
| `go.ate.dev/substrate` | `v1.0.0` (`b34fbee742906494b5eb4f1f36987176bf8770a4`), set by patch 0002 |
| Sam's gist | https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96 at `a625acf1ae16dcc8015d10fed76cf7bd1a75d010` |

## Patches

- `patches/0001-pty-process-streams.patch`: Sam's `0001-companyos-pty-process-streams.patch`, rebased from env `281e860` onto `56424de`.
- `patches/0002-substrate-v1.0.0.patch`: `go.mod`/`go.sum` only. Moves the Substrate module from the v0.6.1 pre-release to v1.0.0. No source change was needed.

### What changed in the rebase

Sam's patch added router mTLS to `ate-env-api` (`-router-client-cert`, `-router-client-key`, `-router-ca`).
Upstream `56424de` ships the same thing natively, so that part of his patch is dropped.
Use the upstream flags instead:

```text
-atenet-credential-bundle=/run/substrate-router-client/credential-bundle.pem
-atenet-ca-file=/run/substrate-router-client/router-ca.pem
```

Sam's `deploy-omp-env-pty.sh` from the gist still passes the old flag names; change them before you use it with this build.
Everything else in his patch is applied unchanged.

## Use

```sh
nix build .#ate-env
./result/bin/ate-env --help
```

As an overlay in another flake:

```nix
inputs.ate-nix.url = "github:<owner>/ate-nix";
# ...
nixpkgs.overlays = [ inputs.ate-nix.overlays.default ];  # then pkgs.ate-env
```

## Update

1. Change `rev` and `hash` in `pkgs/ate-env.nix`; set `vendorHash = lib.fakeHash`.
2. `nix build .#ate-env`. If a patch no longer applies, rework it against the new `rev`; do not loosen it with fuzz.
3. Copy the `got:` hash into `vendorHash` and build again. The build runs the Go tests of the patched packages.
