# Security

## Status

This project is experimental. It has had no security review. [docs/proof.md](docs/proof.md) lists what is tested and what is not. Do not use it to isolate workloads that you do not trust until you have reviewed it yourself.

## Report a vulnerability

Report privately. Do not open a public issue or pull request.

Use GitHub private vulnerability reporting: on the repository page, open **Security**, then **Report a vulnerability**.

Include:

- The commit of this repository.
- What an attacker can do, and what the attacker needs first.
- Steps to reproduce, if you have them.

There is no guaranteed response time. This is a small project with no security team.

## Scope

In scope:

- The patches in `patches/`. Examples: an actor that reads or changes store paths outside its closure, a node that accepts a Nix image against its signature policy, a cache credential that appears in a status or a log.
- The Nix packages, the image builders, the NixOS module, and the scripts in `kind/`.

Not in scope here:

- A vulnerability that is also in unpatched Agent Substrate or env. Report it to those projects: <https://github.com/agent-substrate/substrate> and <https://github.com/agent-substrate/env>.
- A vulnerability in Nix, nixpkgs, gVisor or Kubernetes. Report it to that project.

If you are not sure, report it here.

## Supported versions

Only the latest commit on `main`. There are no releases.

## Known limits

- The trust rule for Nix images is the Nix daemon's signature policy on each node. A node with `require-sigs = false`, or with a trusted key that leaked, accepts images that it must not accept.
- The `kind/` scripts are for a local throwaway cluster. They use an HTTP cache with no login.
