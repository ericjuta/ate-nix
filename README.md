# ate-nix

Run [Agent Substrate](https://ate.dev) actors from Nix store paths, and open real terminals in remote environments.
Two patch sets on top of pinned upstream releases, packaged as a Nix flake. No fork: upstream is fetched by hash and the changes are patch files in this repository.

| Package | Upstream | Adds |
| --- | --- | --- |
| `ate-substrate` | `agent-substrate/substrate` v1.0.0 | **Nix images.** `image: nix:/nix/store/<hash>-<name>` in an actor template. No registry, no image build, no image pull. OCI images continue to work. |
| `ate-env` | `agent-substrate/env` | **PTY streams.** `ate-env <id> shell --tty <command>`: an interactive terminal in a remote environment. Samuel Huber's patch, rebased. |

**Status: experimental.** Nix images are proven on one single-node test cluster. There has been no security review. This project is not affiliated with Agent Substrate. See [docs/proof.md](docs/proof.md).

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

No Nix on your machine? [docs/getting-started.md](docs/getting-started.md) shows the same build with only Docker.
To see an actor boot from a store path on a local throwaway cluster, follow [kind/README.md](kind/README.md).

### Install outside GKE

`ate-substrate` also supplies `ate-setup` and `kubectl-ate`. The installer
includes its pinned manifests, so prebuilt-image deployments work from any
directory:

```sh
nix build .#ate-substrate
./result/bin/ate-setup deploy ate-system --existing-cluster --help
```

The existing-cluster profile uses your kubeconfig rather than GCP discovery
or a local Docker/Kind preflight. It still requires the upstream certificate
APIs, Linux node capabilities, persistent storage, and snapshot storage.
See [docs/operating.md](docs/operating.md) for the complete publishing and
installation procedure, including the older-kernel worker compatibility path.

## Documentation

New here? Start with [docs/README.md](docs/README.md).

| Page | Content |
| --- | --- |
| [Concepts](docs/concepts.md) | Agent Substrate and Nix in plain words. All terms defined. |
| [Getting started](docs/getting-started.md) | Build the packages, with Nix or with Docker only. Use the flake from your own. |
| [Nix images](docs/nix-images.md) | How a store path becomes a running actor. Build and publish an image. |
| [Run it on your cluster](docs/operating.md) | Node setup, the two patched components, trust. |
| [Proof on kind](kind/README.md) | The full local proof, step by step. |
| [Reference project](examples/reference/README.md) | A dev shell, an app, an agent image and a runtime image from one lock file. |
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
