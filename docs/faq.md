# FAQ

**Is this an official Agent Substrate project?**
No. It is an independent set of patches on top of upstream releases. It is not affiliated with Agent Substrate or its maintainers.

**Is it ready for production?**
No. It is proven on one single-node test cluster and has had no security review. [proof.md](proof.md) lists what is tested.

**Do I need NixOS?**
No. Each node needs a Nix installation and a running Nix daemon. The Linux distribution does not matter. The proof ran on a Debian node. A NixOS module exists as a convenience.

**Do I need Nix on my own machine?**
Not to try it. Nix can run in a Docker container: see [getting-started.md](getting-started.md). To build your own images you need Nix somewhere, for example in CI.

**Do OCI images still work?**
Yes. A reference that does not start with `nix:` takes the upstream path, unchanged. Both kinds run on the same node.

**Why not build an OCI image with Nix?**
You can, and upstream supports it today. You still push the image to a registry and each node still pulls and unpacks layers. With a Nix image, the node downloads only the packages that it lacks, and two images share each package that they have in common.

**Why not nix-snapshotter?**
[nix-snapshotter](https://github.com/pdtpartners/nix-snapshotter) makes containerd run ordinary Kubernetes pods from store paths. Substrate does not start actors through containerd: atelet prepares the actor's filesystem itself. This patch puts the store path support there. The two do different jobs: nix-snapshotter is for pods, this patch is for actors.

**Does the node build anything?**
No. The node only downloads built, signed paths. If no trusted cache has a path, the actor does not start.

**Who decides which caches are trusted?**
The node's Nix configuration. A template cannot add a cache or a key.

**Can an agent install packages while it runs?**
Not into its image. The store is read-only inside the actor. The agent can write to its private layer, for example to its home directory.

**What happens to a suspended actor's image?**
The node may delete the view when no actor on that node uses it. When the actor resumes, the node downloads the closure again if necessary. Keep the closure in your cache while the actor exists.

**Which Substrate components do I have to replace?**
Two: `atelet` and `ateapi`. Workers, the router and all other components stay on the upstream release.

**Which versions does this work with?**
Substrate v1.0.0 and env at commit `56424de`. [maintaining.md](maintaining.md) shows how to move to a newer release.

**Where did the patches come from?**
The PTY patch is by Samuel Huber, published as a gist, and rebased here. The Nix image patch was written for this repository after his idea of running Substrate actors from Nix store paths. It is not his code and he has not reviewed it.

**How do I report a problem?**
Open an issue with the template status, the atelet log and the Nix daemon log. [troubleshooting.md](troubleshooting.md) shows where to find them.
