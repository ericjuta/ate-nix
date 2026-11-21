# ate-nix

[Agent Substrate](https://ate.dev) runs sandboxed AI agents ("actors") on Kubernetes, and saves an idle agent to a snapshot until it is needed again.
This repository is a set of patches on top of pinned Agent Substrate releases, packaged as a Nix flake. It is not a fork: upstream is fetched by hash and the changes are patch files here.

New to Agent Substrate or Nix? [docs/README.md](docs/README.md) explains both from nothing.

## What you can do with it

| You can | How | Start at |
| --- | --- | --- |
| **Start an agent from a Nix store path** instead of a container image. No registry, no image build, no image pull. Container images continue to work. | `image: nix:/nix/store/<hash>-<name>` in an actor template | [docs/nix-images.md](docs/nix-images.md) |
| **Open a real terminal in a remote environment.** Full-screen programs, resize, Ctrl-C. Samuel Huber's patch, rebased. | `ate-env <id> shell --tty <command>` | [docs/pty.md](docs/pty.md) |
| **Install Substrate on a cluster that you already have.** Upstream's installer targets Google's GKE or a local test cluster. | `ate-setup deploy --existing-cluster` | [docs/install.md](docs/install.md) |
| **Run Substrate's own pods from a Nix cache too**, with no container registry. Optional. | `nix build .#substrate-nix-bundle`, then `ate-setup --image-map` | [docs/nix-images.md](docs/nix-images.md#registry-free-substrate-system-pods) |
| **Run a real coding agent in an actor.** A worked example with [Oh My Pi](https://github.com/can1357/oh-my-pi) (OMP). It contains no credentials. | `nix build .#omp-image`, then `ate-env <id> shell --tty omp` | [examples/omp](examples/omp/README.md) |
| **Start a [kagent](https://kagent.dev) agent from a Nix store path.** kagent runs its agents on its own Substrate fork; the same patches apply to it. A local proof, not a supported integration. | `nix build .#kagent-adk-image`, then a kagent `Harness` with `image: nix:...` | [docs/kagent.md](docs/kagent.md) |

Each row is usable without the others.

**Status: experimental.** Everything that ran on a cluster ran on a single-node local test cluster. Some parts are tested only without a cluster. There has been no security review. This project is not affiliated with Agent Substrate. [docs/proof.md](docs/proof.md) lists what is tested, feature by feature.

## Why Nix images

A container image is a stack of layers in a registry. Each node pulls and unpacks the layers, and one changed file means a new image.

A Nix image is a store path whose name contains a hash of its build inputs. You build it ahead of time and push it to a binary cache.
A node downloads only the packages that it does not have, checks their signatures against the keys that it trusts, and shows the actor exactly that set of packages. Two images that contain the same package share its files on disk.

```yaml
containers:
- name: agent
  image: nix:/nix/store/0c0zb1l7mqvdrsgjq7b9vl0g9cyfh3q1-agent-env
```

```nix
pkgs.ateNixImage {
  name = "agent-env";
  paths = [ pkgs.bashInteractive pkgs.coreutils pkgs.ripgrep ];
  config = { Entrypoint = [ "/bin/bash" ]; Env = [ "PATH=/bin" ]; };
}
```

## Try it

```sh
git clone https://github.com/ericjuta/ate-nix && cd ate-nix
nix build .#ate-substrate && ./result/bin/atelet --help | grep nix
nix build .#ate-env && ./result/bin/ate-env --help
```

Each build takes a few minutes the first time. No Nix on your machine? [docs/getting-started.md](docs/getting-started.md) shows the same build with only Docker.
To see an actor boot from a store path on a local throwaway cluster, follow [kind/README.md](kind/README.md).

## Documentation

New here? Start with [docs/README.md](docs/README.md).

| Page | Content |
| --- | --- |
| [Concepts](docs/concepts.md) | Agent Substrate and Nix in plain words. All terms defined. |
| [Getting started](docs/getting-started.md) | Build the packages, with Nix or with Docker only. Use the flake from your own. |
| [Nix images](docs/nix-images.md) | How a store path becomes a running actor. Build and publish an image. |
| [Install on your cluster](docs/install.md) | Install Substrate on a Kubernetes cluster that is not GKE: prerequisites, images, snapshot storage, deploy. |
| [Enable Nix images](docs/operating.md) | Node setup, the two patched components, trust, revocation. |
| [Proof on kind](kind/README.md) | The full local proof, step by step. |
| [Reference project](examples/reference/README.md) | A dev shell, an app, an agent image and a runtime image from one lock file. |
| [OMP example](examples/omp/README.md) | A coding agent in a Nix image, used through the remote terminal. |
| [PTY streams](docs/pty.md) | The remote terminal. |
| [What is proven](docs/proof.md) | Tested and not tested. |
| [Troubleshooting](docs/troubleshooting.md) | Errors, causes, fixes. |
| [Maintaining](docs/maintaining.md) | Layout, pins, how to update and change a patch, how to contribute. |
| [FAQ](docs/faq.md) | NixOS? nix-snapshotter? Production? |

## Contribute, report, licence

- To contribute: [CONTRIBUTING.md](CONTRIBUTING.md).
- To report a vulnerability: [SECURITY.md](SECURITY.md). Do not open a public issue.
- Licence: Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Credits

- [Agent Substrate](https://github.com/agent-substrate/substrate) and [env](https://github.com/agent-substrate/env) are Apache-2.0 projects by their authors.
- The PTY patch is by Samuel Huber ([gist](https://gist.github.com/SamuelLHuber/5d420731d5d6bbd034daa8f02eae9b96)).
- The Nix image patch follows his idea of running Substrate actors from Nix store paths. It was written for this repository. It is not his code and he has not reviewed it.
