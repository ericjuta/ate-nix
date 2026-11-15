# ate-nix documentation

Start here if you have never seen this repository, Agent Substrate or Nix.

## What this repository is

[Agent Substrate](https://ate.dev) runs sandboxed agents on Kubernetes.
This repository adds four things through patches and packages on top of pinned upstream releases. Each one is usable without the others.

1. **Nix images.** An agent's filesystem can come from a Nix store path instead of a container image. No registry, no image build, no image pull.
2. **PTY streams.** `ate-env` can open a real interactive terminal in a remote environment.
3. **An installer for your own cluster.** Upstream's installer targets Google's GKE or a local test cluster. The patched `ate-setup` also installs on a Kubernetes cluster that you already have.
4. **Registry-free system pods.** Optional. Substrate's own services and workers can also come from a Nix cache instead of a container registry. This does not change how actors get their images (item 1), and it does not create the Kubernetes cluster for you.

There is also one worked example: the [OMP](https://github.com/can1357/oh-my-pi) coding agent packaged as a Nix image, which you drive through the remote terminal.

Nothing here is a fork. Upstream source is fetched by hash, the patches are applied at build time, and Nix builds the result.

This project is not affiliated with Agent Substrate. It is experimental: read [proof.md](proof.md) before you depend on it.

## Reading order

| You want to | Read |
| --- | --- |
| Understand the words (actor, closure, binary cache, ...) | [concepts.md](concepts.md) |
| Build the binaries and look at them | [getting-started.md](getting-started.md) |
| Understand how a Nix image becomes a running actor, and build one | [nix-images.md](nix-images.md) |
| Install Substrate on your own cluster (not GKE, not kind) | [install.md](install.md) |
| Enable Nix images on a cluster that runs Substrate | [operating.md](operating.md) |
| Run a real coding agent (OMP) in an actor | [../examples/omp/README.md](../examples/omp/README.md) |
| Deploy supported system pods without a container registry; compare nix-csi and nix-snapshotter | [nix-images.md](nix-images.md#registry-free-substrate-system-pods) |
| See it work on a local throwaway cluster | [../kind/README.md](../kind/README.md) |
| Start your own project on top of it | [../examples/reference/README.md](../examples/reference/README.md) |
| Use the remote terminal | [pty.md](pty.md) |
| Know what is tested and what is not | [proof.md](proof.md) |
| Fix an error | [troubleshooting.md](troubleshooting.md) |
| Update a pin, change a patch, contribute | [maintaining.md](maintaining.md) |
| Ask "why not ...?" | [faq.md](faq.md) |

## The short path

1. Read [concepts.md](concepts.md). It takes five minutes.
2. Build one package with [getting-started.md](getting-started.md). You need Nix, or only Docker.
3. Run the local proof in [../kind/README.md](../kind/README.md). Its first lines list the tools that you need. A full run took about 20 minutes.

You can stop after any step. Steps 1 and 2 need no cluster.
