# FAQ

**Is this an official Agent Substrate project?**
No. It is an independent set of patches on top of upstream releases. It is not affiliated with Agent Substrate or its maintainers.

**Is it ready for production?**
No. Everything that ran on a cluster ran on a single-node local test cluster, and nothing has had a security review. [proof.md](proof.md) lists what is tested, feature by feature.

**Do I need NixOS?**
No. Each node needs a Nix installation and a running Nix daemon. The Linux distribution does not matter. The proof ran on a Debian node. A NixOS module exists as a convenience.

**Do I need Nix on my own machine?**
Not to try it. Nix can run in a Docker container: see [getting-started.md](getting-started.md). To build your own images you need Nix somewhere, for example in CI.

**Do OCI images still work?**
Yes. A reference that does not start with `nix:` takes the upstream path, unchanged. Both kinds run on the same node.

**Why not build an OCI image with Nix?**
You can, and upstream supports it today. You still push the image to a registry and each node still pulls and unpacks layers. With a Nix image, the node downloads only the packages that it lacks, and two images share each package that they have in common.

**How do nix-snapshotter and nix-csi fit?**
The optional [nix-snapshotter integration](nix-images.md#registry-free-substrate-system-pods) runs supported Substrate system and worker pods through containerd using signed Nix closures. Substrate actors do not start through containerd: atelet prepares their filesystem itself, using the independent `nix:/...` interface. Both are needed to remove conventional image publication from the supported deployment.

nix-csi delivers closures as volumes or mounts but leaves container-image bootstrap and workload command/environment adaptation to the operator. Snapshotter preserves existing pod image configuration instead. Neither choice makes Kubernetes bootstrap disappear. Snapshotter avoids conventional registry images but still creates OCI metadata archives and small filesystem descriptors; see the linked guide for that boundary and the source-backed comparison.

**Does the node build anything?**
No. The node only downloads built, signed paths. If no trusted cache has a path, the actor does not start.

**Who decides which caches are trusted?**
The node's Nix configuration. A template cannot add a cache or a key.

**Can an agent install packages while it runs?**
Not into its image. The image under the actor is read-only. What the agent writes, under `/nix/store` too, goes to the actor's private layer. It does not reach the node's store, the image, or another actor. The actor has no Nix daemon, so `nix build` and `nix-env` do not work there.

**What happens to a suspended actor's image?**
The node may delete the view when no actor on that node uses it. When the actor resumes, the node downloads the closure again if necessary. Keep the closure in your cache while the actor exists.

**Which Substrate components do I have to replace?**
It depends on the feature.

- **Nix actor images:** two, `atelet` and `ateapi`. Workers, the router and all other components stay on the upstream release.
- **Older node kernels (before Linux 6.6.23):** also the worker images, which carry the overlay mount fallback. See [install.md](install.md#publish-a-complete-oci-release).
- **PTY streams:** the three env programs (`ate-env`, `ate-env-api`, `ate-env-guest`). Substrate itself is unchanged.
- **Registry-free system pods:** none are replaced one by one. The installer takes every pod reference from an image map. See [nix-images.md](nix-images.md#registry-free-substrate-system-pods).

**What is OMP, and do I need it?**
[Oh My Pi](https://github.com/can1357/oh-my-pi) is an open-source coding agent that runs in a terminal. This repository packages it as one example of a real agent in a Nix image. You do not need it for anything else here. See [../examples/omp/README.md](../examples/omp/README.md).

**How long does a build take?**
A few minutes for one package. One to two hours for everything from an empty store, because the registry-free bundle and the OMP image compile large programs. [getting-started.md](getting-started.md#time-and-disk) has the numbers.

**Which versions does this work with?**
Substrate v1.0.1 and env at commit `56424de`. [maintaining.md](maintaining.md) shows how to move to a newer release.

**Where did the patches come from?**
The PTY patch is by Samuel Huber, published as a gist, and rebased here. The Nix image patch was written for this repository after his idea of running Substrate actors from Nix store paths. It is not his code and he has not reviewed it.

**How do I report a problem?**
Open an issue with the template status, the atelet log and the Nix daemon log. [troubleshooting.md](troubleshooting.md) shows where to find them.
