# Concepts

This page assumes no knowledge of Agent Substrate or Nix. Each term is defined once and used the same way in all other pages.

## Agent Substrate in one paragraph

Agent Substrate is an open-source runtime that runs untrusted workloads, usually AI agents, on Kubernetes.
Each workload runs in a sandbox (gVisor or a microVM).
Agents wait most of the time, so Substrate saves an idle agent to a snapshot and frees its machine. It restores the agent when a request arrives.
The upstream documentation is at <https://ate.dev/docs/>.

| Term | Meaning |
| --- | --- |
| **Snapshot** | The saved state of a stopped workload: its memory and its files. Substrate keeps snapshots in object storage (an S3 or GCS bucket). |
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
| **Signature** | Each path in a binary cache can carry a signature made with the cache's private key. A machine lists the public keys that it trusts. With the setting `require-sigs` on in the machine's Nix configuration (`nix.conf`), the machine refuses a path that no trusted key signed. |
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

**Pod images** are a separate, optional feature. An actor is not a Kubernetes pod, but Substrate's own services and workers are, and normally they come from a container registry too. They can come from a Nix cache instead. The rest of this paragraph is for operators who want that. Kubernetes starts Substrate's own services and
workers through containerd; actors are started by atelet. The optional
nix-snapshotter module lets containerd realize signed closures from a Nix cache
using `nix:0...` archive references. These archives retain OCI image configuration
and small directory/mountpoint layers, not conventional application image layers
fetched from a registry. The installer image map keeps pod references separate
from actors' `nix:/...` roots. See [nix-images.md](nix-images.md#registry-free-substrate-system-pods)
for publication, bootstrap requirements, and supported deployments.

## Other names you will meet

These are not needed for the short path. Come back when a page uses one.

| Term | Meaning |
| --- | --- |
| **kind** | "Kubernetes in Docker": a tool that runs a throwaway Kubernetes cluster in Docker containers on one machine. The local proof uses it. |
| **GKE** | Google Kubernetes Engine. The upstream installer assumes it, or kind. |
| **gVisor**, **microVM** | The two sandbox types of Substrate. gVisor needs no hardware support. A microVM needs KVM (`/dev/kvm`). All cluster tests here used gVisor. |
| **containerd** | The program on a Kubernetes node that starts containers for pods. Substrate's own services and workers are pods, so containerd starts them. It does not start actors: atelet does. |
| **ko** | A tool that builds Go programs into container images. Upstream Substrate builds its images with it. In images built that way, the program is at `/ko-app/<name>`. |
| **narinfo** | The small text file that a binary cache holds for each store path: its content hash, its size, the paths it needs, and its signatures. A node reads the narinfo before it downloads the path. |
| **nix-snapshotter** | A containerd plugin from another project. With it, containerd can start a pod from a Nix closure instead of image layers. This repository uses it only for the registry-free system pods. |
| **nix-csi** | A different project with a similar aim: it gives a pod a Nix closure as a volume. This repository does not use it. [nix-images.md](nix-images.md#why-nix-snapshotter-rather-than-nix-csi) compares the two. |
| **Image map** | A file for the installer that says, for each Substrate component, which image reference to deploy. The registry-free path generates one that points at Nix closures. |
| **ate-setup**, **kubectl-ate** | The Substrate installer, and the `kubectl` plugin that manages templates and actors (`kubectl ate ...`). Both are upstream programs. This repository builds patched versions of them. |
| **System pods** | Substrate's own services on the cluster (API server, controller, router, atelet), as opposed to the actors that it runs for you. |
| **OMP** | [Oh My Pi](https://github.com/can1357/oh-my-pi), an open-source coding agent that runs in a terminal. This repository packages it as an example of a real agent in a Nix image. |
| **kagent** | [kagent](https://kagent.dev), an open-source agent framework for Kubernetes. Since its version 1.0 it runs each agent session as a Substrate actor, on its own fork of Substrate. [kagent.md](kagent.md) defines its terms (Agent, Harness, ModelConfig, Session) and starts one of its agents from a Nix image. |

## How the repository is built

A **patch stack** is a list of patch files that are applied, in order, to a pinned upstream commit.
This repository stores no upstream code. `pkgs/*.nix` names the upstream commit and its hash, and `patches/` holds the changes.
When upstream publishes a release, you change the pin and, if a patch no longer applies, you rework that patch. See [maintaining.md](maintaining.md).
