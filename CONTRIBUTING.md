# Contributing

Thank you for your help. This project is small and experimental, so the rules are short.

## Before you start

- Read [docs/README.md](docs/README.md) if the project is new to you.
- [docs/maintaining.md](docs/maintaining.md) is the working guide: layout, upstream pins, how to update a pin, how to change a patch.
- For a large change, open an issue first and describe the plan.
- A bug in unpatched Agent Substrate or env belongs upstream: <https://github.com/agent-substrate/substrate/issues> or <https://github.com/agent-substrate/env/issues>.
- A vulnerability does not go into an issue or a pull request. See [SECURITY.md](SECURITY.md).

## What a good change looks like

- One subject per pull request.
- A patch applies to its pinned upstream commit with no fuzz and no rejected hunk.
- One patch per feature. Dependency changes (`go.mod`, `go.sum`) go into a separate patch.
- New behaviour in a patch has a Go test in the same patch.
- The documentation agrees with the change. Define a new term once, in [docs/concepts.md](docs/concepts.md).

## Checks

Run these before you open a pull request. CI runs them too.

```sh
nix flake check -L
(cd examples/reference && nix flake check -L)
```

No Nix on your machine? [docs/getting-started.md](docs/getting-started.md) shows the Docker form of these commands.

CI does not start a cluster. A change to `patches/substrate/` or to `kind/` also needs the local proof in [kind/README.md](kind/README.md): `kind/prove.sh` and `kind/private-cache.sh`. Say in the pull request if you ran it. If you did not, say that too.

## Proof

[docs/proof.md](docs/proof.md) lists only results that a person saw. If you add a proven claim, say in the pull request how you saw it. All other items go into "Not proven".

## Licence of contributions

This repository is Apache-2.0. A contribution that you send is under the same licence (section 5 of [LICENSE](LICENSE)). Send only work that you have the right to license this way.
