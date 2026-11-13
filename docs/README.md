# ate-nix documentation

Start here if you have never seen this repository, Agent Substrate or Nix.

## What this repository is

[Agent Substrate](https://ate.dev) runs sandboxed agents on Kubernetes.
This repository adds two features to it, as patch files on top of pinned upstream releases:

1. **Nix images.** An agent's filesystem can come from a Nix store path instead of a container image. No registry, no image build, no image pull.
2. **PTY streams.** `ate-env` can open a real interactive terminal in a remote environment.

Nothing here is a fork. Upstream source is fetched by hash, the patches are applied at build time, and Nix builds the result.

This project is not affiliated with Agent Substrate. It is experimental: read [proof.md](proof.md) before you depend on it.

## Reading order

| You want to | Read |
| --- | --- |
| Understand the words (actor, closure, binary cache, ...) | [concepts.md](concepts.md) |
| Build the binaries and look at them | [getting-started.md](getting-started.md) |
| Understand how a Nix image becomes a running actor, and build one | [nix-images.md](nix-images.md) |
| Run it on your own cluster | [operating.md](operating.md) |
| See it work on a local throwaway cluster | [../kind/README.md](../kind/README.md) |
| Use the remote terminal | [pty.md](pty.md) |
| Know what is tested and what is not | [proof.md](proof.md) |
| Fix an error | [troubleshooting.md](troubleshooting.md) |
| Update a pin, change a patch, contribute | [maintaining.md](maintaining.md) |
| Ask "why not ...?" | [faq.md](faq.md) |

## The short path

1. Read [concepts.md](concepts.md). It takes five minutes.
2. Build one package with [getting-started.md](getting-started.md). You need Nix, or only Docker.
3. Run the local proof in [../kind/README.md](../kind/README.md). Its first lines list the tools that you need. Allow about half an hour, most of it the upstream install.
