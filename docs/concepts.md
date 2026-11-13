# Concepts

This page assumes no knowledge of Agent Substrate or Nix. Each term is defined once and used the same way in all other pages.

## Agent Substrate in one paragraph

Agent Substrate is an open-source runtime that runs untrusted workloads, usually AI agents, on Kubernetes.
Each workload runs in a sandbox (gVisor or a microVM).
Agents wait most of the time, so Substrate saves an idle agent to a snapshot and frees its machine. It restores the agent when a request arrives.
The upstream documentation is at <https://ate.dev/docs/>.

| Term | Meaning |
| --- | --- |
| **Actor** | One running, stateful workload: one agent, one environment. Substrate can suspend it to a snapshot and resume it later, with its memory and files intact. |
| **Actor template** | The recipe for an actor: which image, which command, how much CPU and memory. Many actors start from one template. A template cannot be changed after it is created. |
| **Golden snapshot** | The snapshot Substrate takes when it starts a template for the first time. New actors start from this snapshot, which is why they start fast. A template with a golden snapshot has proven that its image boots. |
| **Worker** | A Kubernetes pod that holds a sandbox ready. An actor runs inside a worker while it is active. A **worker pool** is a group of identical workers. |
| **Atespace** | Substrate's own namespace: a group of templates and actors. |
| **atelet** | The Substrate agent on each node. It prepares the actor's filesystem and tells the worker to start the actor. This repository patches it. |
| **ateapi** | The Substrate API server. It validates templates. This repository patches it to accept a new kind of image reference. |
| **env** | A second upstream project, `agent-substrate/env`. It adds an "environment" API on top of actors: run a command, read and write files. Its command-line tool is `ate-env`. |

## Container images, and why replace them

Upstream Substrate takes the actor's filesystem from an **OCI image**: the image format that Docker and Kubernetes use.
An image is a stack of compressed layers in a **registry**. To start an actor on a node, atelet must download the layers and unpack them.
To change one file you build a new image, push it and pull it again.

## Nix in one paragraph

Nix is a package manager that builds each package into its own directory under `/nix/store`.
The directory name starts with a hash of everything that went into the build, for example `/nix/store/0c0zb1l7mqvdrsgjq7b9vl0g9cyfh3q1-ripgrep-14.1`.
The hash covers the inputs (sources, dependencies, build instructions), not the bytes that the build produced. For most packages, two builds from different inputs get different names.
The name alone does not prove what the files contain. That proof is the signature: a cache key signs the name together with a hash of the content, and a node takes a path only when a key that it trusts has signed it.

| Term | Meaning |
| --- | --- |
| **Store path** | One directory under `/nix/store`. It holds one package, or one tree that links to other packages. |
| **Closure** | A store path plus every store path it needs to run, and nothing else. The closure of `bash` is `bash` and its C library, not the whole store. |
| **Binary cache** | An HTTP server that holds built store paths. Any static file server works. The public one for the Nix package set is `cache.nixos.org`. |
| **Substitute** | To download a built store path from a binary cache instead of building it. A cache is also called a **substituter**. |
| **Signature** | Each path in a binary cache can carry a signature made with the cache's private key. A machine lists the public keys that it trusts. With `require-sigs` on, the machine refuses a path that no trusted key signed. |
| **Nix daemon** | The service on a machine that owns `/nix/store`. Other programs ask it to substitute paths. |
| **GC root** | A marker that tells the Nix garbage collector "keep this path and its closure". |
| **Flake** | A Nix project with a `flake.nix` file that lists its inputs (pinned) and outputs (packages, modules). This repository is a flake. |
| **Overlay** | A Nix function that adds or changes packages in the package set. Your own flake can import this repository's overlay and get its packages. |

## What this repository adds

**A Nix image** is a store path used as an actor's filesystem. A template names it like this:

```yaml
containers:
- name: agent
  image: nix:/nix/store/0c0zb1l7mqvdrsgjq7b9vl0g9cyfh3q1-agent-env
```

You build that store path ahead of time, on your own machine or in CI, and push its closure to your binary cache.
When an actor starts, the node substitutes only the store paths that it does not have yet.
The actor then sees exactly that closure as its root filesystem.

| With an OCI image | With a Nix image |
| --- | --- |
| Build an image, push it to a registry | Build a store path, push it to a binary cache |
| The node pulls and unpacks layers | The node downloads only the packages it lacks |
| Two images that both contain Node.js store it twice, unless they share a layer | Two images that both contain the same Node.js share the same files on disk |
| Pinned by a digest of the content that you must write into the template | Pinned by the store path, which names the build inputs. A trusted signature ties that path to its content |
| Trust comes from the registry and your pull credentials | Trust comes from signatures: the node takes only paths that a key it trusts has signed |

A **view** is the directory that atelet builds for one Nix image. It contains hard links to the store paths of the closure and to nothing else. The worker mounts the view as the read-only bottom layer of the actor's filesystem.

**PTY streams** are independent of Nix images. A PTY (pseudo-terminal) is what makes a remote shell behave like a local one: full-screen programs, colours, window resize. Upstream `ate-env` runs a command and returns its output. With the patch, it can also attach your terminal to the remote command. See [pty.md](pty.md).

## How the repository is built

A **patch stack** is a list of patch files that are applied, in order, to a pinned upstream commit.
This repository stores no upstream code. `pkgs/*.nix` names the upstream commit and its hash, and `patches/` holds the changes.
When upstream publishes a release, you change the pin and, if a patch no longer applies, you rework that patch. See [maintaining.md](maintaining.md).
