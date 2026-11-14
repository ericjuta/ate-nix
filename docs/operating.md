# Run it on your cluster

Install Agent Substrate on an existing non-GKE Kubernetes cluster, then
optionally enable `image: nix:/nix/store/...` for actors. No Nix snapshotter,
Nix CSI driver, or NixOS node is required for this OCI-based installation.
For a local Kind cluster, see [../kind/README.md](../kind/README.md).

## Requirements

- A Kubernetes cluster meeting the prerequisites below. Install patched
  Substrate v1.0.0 with the portable installer, or use an existing compatible
  installation.
- Nix on each node that runs Nix images. NixOS is not required: any Linux distribution with a Nix installation works.
- A binary cache that the nodes can reach, and its public signing key. For packages from the public Nix package set, `cache.nixos.org` is enough.

Nix and a binary cache are needed only for Nix **actor** images, not to run
Substrate's OCI system pods. If Substrate is already installed, skip to
[prepare each node](#1-prepare-each-node). Otherwise bootstrap it first.

## Cluster prerequisites

This installer does not create or reconfigure a Kubernetes cluster. The
`--existing-cluster` flag selects a nonlocal, non-GKE installation profile; it
is not a blanket compatibility claim for every managed Kubernetes service.

- **Certificate APIs and projections.** The pinned upstream bootstrap enables
  `ClusterTrustBundle`, `ClusterTrustBundleProjection`, and
  `PodCertificateRequest`, and serves `certificates.k8s.io/v1beta1` through
  API-server `--runtime-config=certificates.k8s.io/v1beta1=true`. Its comments
  note that these are not all enabled by default even in Kubernetes 1.36.
  Enable the applicable gates on the API server and kubelets according to
  your distribution. Older alpha-only certificate APIs are not sufficient
  for this pin. Verify both resources and pod-volume projection support;
  checking the Kubernetes version alone is insufficient.
- **Certificate controller.** The installer deploys Substrate's
  `podcertificate-controller` and its CA pools. cert-manager is not a
  substitute for `PodCertificateRequest` or `ClusterTrustBundle`, and installing
  CRDs with those names does not enable the built-in APIs or projections.
- **Permissions and admission.** Use an administrative kubeconfig able to
  manage namespaces, CRDs, cluster RBAC, admissionregistration.k8s.io/v1
  ValidatingAdmissionPolicies, and cluster trust bundles. The install uses
  the canonical `ate-system` namespace. Node/pod admission must allow the
  host paths, device plugins, mount propagation, and worker capabilities in
  the upstream manifests.
- **Nodes and networking.** Linux nodes need overlayfs, cgroup v2, and the
  standard `/var/lib/kubelet/plugins` and `/var/lib/kubelet/device-plugins`
  paths. A NetworkPolicy-capable CNI, cluster DNS, service-account token/OIDC
  discovery, and pod-to-pod connectivity are required. Match the upstream
  node networking prerequisites, including proxy ARP/NDP where needed by
  your CNI; the installer does not set host sysctls. Micro-VM pools also need
  `/dev/kvm`, suitable virtualization support, and staged sandbox assets.
- **Kernel compatibility.** Linux 6.7+, or Linux 6.6.23+ with the backport,
  supports the upstream incremental `lowerdir+` mount API. Patched **worker
  images** also support legacy overlay mounts on kernels such as Linux 6.1.
  On that path the full option string must fit in one page and directory paths
  must contain no colon, comma, backslash, or NUL. Large layer counts need a
  kernel with `lowerdir+` support. Permission,
  upper/work-directory, and mount-attachment failures are not bypassed.
- **Persistent storage.** Provide a default StorageClass, explicitly select one
  with `--ateapi-postgres-storage-class`, or configure external PostgreSQL.
  This profile preserves the nonlocal PostgreSQL defaults: a **500Gi RWO
  claim**, with requests of 2 CPU and 1Gi RAM. It does not silently substitute
  Kind's small development volume. `/var/lib/ate` also needs adequate local
  disk capacity, IOPS, and mount propagation.
- **Object storage and images.** Provision S3-compatible snapshot storage as
  described below. The installer and Kubernetes nodes need read access to
  the component registry; nodes also need the third-party images pinned by
  the manifests, including PostgreSQL and the chosen network dataplane.
  Private-registry access for Kubernetes system pods is a node/kubelet
  responsibility. The portable profile removes GKE's host-specific image
  credential-provider flags and mounts from atelet; actor OCI images must
  be public or use registry authentication configured separately.

Check the actual API resources before installing:

```sh
export KUBECONFIG=/absolute/path/to/kubeconfig
CONTEXT=your-existing-context

kubectl --context="$CONTEXT" get --raw /apis/certificates.k8s.io/v1beta1
kubectl --context="$CONTEXT" api-resources --api-group=certificates.k8s.io
kubectl --context="$CONTEXT" api-resources --api-group=admissionregistration.k8s.io
kubectl --context="$CONTEXT" get storageclasses
```

The certificate API response must include `podcertificaterequests` and
`clustertrustbundles`. A service that cannot enable the required APIs/gates
cannot run this pinned Substrate release using this installer.

## Publish a complete OCI release

The operator may consume an existing release instead of building one. It must
come from this patched source: an unpatched upstream worker does not have the
older-kernel fallback, and unpatched atelet/ateapi do not support Nix actor
images.

The flake's `atelet-image` and `ateapi-image` are useful replacements for an
existing install, **not** a complete component set. Publish the entire set once
from a Linux build machine. Requirements: Nix, Git configured with your author
identity, a working Docker daemon with buildx, registry push credentials
(`docker login` or equivalent), and network
access to the pinned Go tool dependencies and image bases. ko is pinned by
upstream's `hack/tools/ko/go.mod` and is built/resolved by Go, not an unpinned
host ko installation. Envoy is built by Docker buildx from its pinned
Dockerfile, including its Rust module.

Run from this checkout initially:

```sh
ATE_NIX="$PWD"
ATE_PACKAGE="$(nix build --no-link --print-out-paths .#ate-substrate)"
PATCHED_SRC="$(nix build --no-link --print-out-paths .#ate-substrate.patchedSrc)"
IMAGE_REPO=registry.example.com/substrate
IMAGE_TAG=v1.0.0-ate-nix
BUILD_DIR="$(mktemp -d)"

# Publish from a writable copy, retaining every manifest, .ko.yaml, ko module,
# Dockerfile, ko-data directory, and worker source from the same patched pin.
cp -R "$PATCHED_SRC/." "$BUILD_DIR/"
chmod -R u+w "$BUILD_DIR"

# The fetched Nix source has no .git. Upstream's release publisher requires
# provenance from a real commit; this records the full patched snapshot.
git -C "$BUILD_DIR" init --initial-branch=build
git -C "$BUILD_DIR" add --force --all
git -C "$BUILD_DIR" commit -m "Snapshot ate-nix patched Substrate v1.0.0"

# The package's development environment supplies its pinned Go 1.27 toolchain.
# Docker/buildx and registry credentials remain those of the publishing host.
# Override the sandbox's Go module/cache settings for this networked publish.
nix develop "$ATE_NIX#ate-substrate" --command env \
  ATE_SOURCE_ROOT="$BUILD_DIR" VERSION="$IMAGE_TAG" ATE_CONFIG="" \
  GOFLAGS="" GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org \
  GOPATH="$HOME/.cache/ate-nix-go" GOCACHE="$HOME/.cache/ate-nix-go-build" \
  "$ATE_PACKAGE/bin/ate-setup" publish release-images \
    --no-dev-env --image-repo="" --image-tag="" \
    --ko-docker-repo="$IMAGE_REPO" --ko-default-platforms=linux/amd64
```

Use `linux/arm64`, or the comma-separated platforms your builder can actually
build, for other nodes. `publish` does not construct Kubernetes clients or need
a kubeconfig. Use a unique release-shaped tag for each patched source revision,
and retain the pushed digest references it prints. The revision label names
your committed patched snapshot, not an unmodified upstream checkout.
Reruns leave an already-complete tag alone; only use `--overwrite` when you
intend to replace it.

`publish release-images` publishes the full system set: 10 Go components
(`ate-idp-server`, `ateapi`, `atecontroller`, `atelet`, `atenet`,
`ateworker-gvisor`, `ateworker-microvm`, `kubernetes-secrets`,
`objectstore-plugin`, and `podcertcontroller`) plus **`envoy-dataplane`**.
No worker or Envoy image is left for the installer to invent later.
Upstream intentionally excludes demos and benchmarking fakes from a release;
those are not needed by the real control plane.

Installing those prebuilt images with `--sandbox-classes=gvisor` needs neither
Go/ko nor Docker. Source
publishing does; the `ate-setup` package deliberately does not pull those
large build tools into a prebuilt-only operator installation.

## Provision snapshot storage

Create the bucket before installing. Both object-store sidecars use the same
S3 settings. Allow bucket listing and object get/put/delete/head, server-side
copy, multipart upload/copy/complete/abort, and any encryption-key access your
bucket policy requires. Provision lifecycle/retention deliberately: deleting
live snapshot objects loses resumable actor state.

Prepare a mode-0600 AWS environment file outside this checkout using your
credential manager. Its shape is:

```ini
AWS_REGION=your-region
AWS_ENDPOINT_URL=https://s3.example.com
AWS_S3_USE_PATH_STYLE=true
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
```

Omit `AWS_ENDPOINT_URL` for the AWS default endpoint, and set path-style
addressing only if your endpoint requires it. Temporary credentials also need
`AWS_SESSION_TOKEN`. The HTTPS endpoint must chain to a CA trusted by the
object-store plugin image; private CAs need a corresponding trusted CA mount
or custom image, not TLS verification disabled.

Create the Secret without putting credentials in command-line arguments:

```sh
kubectl --context="$CONTEXT" create namespace ate-system \
  --dry-run=client -o yaml | kubectl --context="$CONTEXT" apply -f -

kubectl --context="$CONTEXT" -n ate-system create secret generic ate-snapshot-storage \
  --from-env-file=/absolute/path/to/snapshot-storage.env \
  --dry-run=client -o yaml | kubectl --context="$CONTEXT" apply -f -
```

The portable profile imports this Secret into the API-server and atelet
**object-store sidecars only**, not the main processes or actor containers.
It creates no bucket, RustFS, local registry, or monitoring stack. S3 uses
these plugin credentials for every actor; unlike the GCS backend, it does
not downscope credentials per actor. Restrict Secret access accordingly.
After rotating the Secret, restart `deployment/ate-api-server` and
`daemonset/atelet` so their sidecars read the new values.

## Configure and deploy

Write an installation document outside the checkout. This example uses
upstream's Envoy dataplane, allows its generic bootstrap client identity, and
explicitly disables optional egress credential injection. Choose those
settings for your installation rather than inheriting another deployment's
policy.

```yaml
apiVersion: install.ate.dev/v1alpha1
kind: SubstrateInstall
existingCluster:
  enabled: true
context: your-existing-context
images:
  repo: registry.example.com/substrate
  tag: v1.0.0-ate-nix
storage:
  bucketName: substrate-snapshots
  snapshotLocation: s3://substrate-snapshots/snapshots/
ingressAllowedSPIFFEIDs: spiffe://cluster.local/ns/ate-system/sa/ate-client
atenet:
  egress:
    credentialProvider: '{"enabled":false}'
rolloutTimeout: 5m
```

Use your provisioned bucket, image repository/tag and actual context. Set
`ateapi.postgres.storageClass` if there is no suitable default, or supply
`ateapi.postgres.readWrite.connectionString` and
`ateapi.postgres.owner.connectionString` for an external database.
`--ateapi-expected-jwt-issuer` overrides OIDC discovery if the service-account
issuer differs from the cluster's discovery response. To export Go-service
telemetry, supply `--otlp-endpoint` for a collector you operate; none is
installed by this profile. The portable Agentgateway router omits its
optional tracing policy rather than referring to a GKE collector.

```sh
INSTALL_CONFIG=/absolute/path/to/substrate-install.yaml
(
  cd /tmp
  "$ATE_PACKAGE/bin/ate-setup" deploy ate-system \
    --config="$INSTALL_CONFIG" --kubeconfig="$KUBECONFIG" \
    --sandbox-classes=gvisor --no-dev-env --no-report-defaults
)
```

The explicit `--sandbox-classes=gvisor` is important. Upstream defaults to
installing both sandbox classes and automatically assembling/staging microVM
assets through a GKE/GCS or Kind-specific bootstrap path. That is not a
portable S3 staging mechanism. This guide leaves the global default unchanged
and selects gVisor deliberately. To add microVM pools, provision `/dev/kvm`,
stage the SHA-256-pinned guest/VMM assets separately, and apply a microVM
`SandboxConfig` with `s3://` asset URLs served by the configured object-store
plugin; do not invoke the GKE-specific automatic staging path for this profile.

`--existing-cluster`, `ATE_EXISTING_CLUSTER=true`, and the file's
`existingCluster: {enabled: true}` are equivalent configuration channels, with normal
flag-over-file-over-environment precedence. It is mutually exclusive with
`--kind`. With neither, upstream's GKE defaults remain unchanged. It does
not run Docker/Kind preflight, create a cluster, fetch GKE credentials, or
source `.ate-dev-env.sh`.

The wrapper supplies `ATE_SOURCE_ROOT` to locate pinned resources without
changing directory. Both absolute paths above and relative paths from the
caller's directory work. A prebuilt deploy resolves registry tags to digests,
so the operator also needs registry read credentials, not only the nodes.

### Outside-checkout configuration smoke

There is no upstream configuration-only/dry-run deploy flag. This deliberately
failing smoke exercises relative config loading outside the checkout while
preventing cluster mutations with an explicitly nonexistent kubeconfig:

```sh
SMOKE_DIR="$(mktemp -d)"
cp "$INSTALL_CONFIG" "$SMOKE_DIR/install.yaml"
(
  cd "$SMOKE_DIR"
  "$ATE_PACKAGE/bin/ate-setup" --help
  "$ATE_PACKAGE/bin/kubectl-ate" --help
  if "$ATE_PACKAGE/bin/ate-setup" deploy ate-system \
      --config=./install.yaml --kubeconfig="$SMOKE_DIR/absent-kubeconfig" \
      --record-dir="$SMOKE_DIR/records" --sandbox-classes=gvisor \
      --no-dev-env --no-report-defaults; then
    echo "ERROR: missing kubeconfig was accepted" >&2
    exit 1
  fi
)
```

The expected failure names `while reading kubeconfig` and the missing file.
It must **not** say `no go.mod found`, invoke Docker/ko, or fail to find the
relative installation document. This is not a successful cluster deployment.

### Cluster smoke

```sh
kubectl --context="$CONTEXT" -n podcertificate-controller-system \
  rollout status deployment/podcertificate-controller --timeout=5m
for deployment in ate-api-server ate-idp-server ate-controller atenet-router atenet-egress; do
  kubectl --context="$CONTEXT" -n ate-system \
    rollout status deployment/"$deployment" --timeout=5m
done
kubectl --context="$CONTEXT" -n ate-system rollout status daemonset/atelet --timeout=5m
kubectl --context="$CONTEXT" get clustertrustbundles
```

Rollouts should complete and Substrate signer trust bundles should be present.
Then deploy a real actor with the prebuilt worker image and exercise
suspend/resume against your S3 bucket. Readiness alone does not prove snapshot
durability or that your CNI supports actor traffic. The existing Nix actor
proof is described at the end of this page.

For Nix actor images there are three additional steps: prepare the node,
replace atelet/ateapi if the installation did not use this patched release,
and give atelet the store.

## 1. Prepare each node

A node needs:

1. **A running Nix daemon** whose configuration lists your caches (`substituters`) and your keys (`trusted-public-keys`), with `require-sigs = true`. The trust rules are here and only here.
2. **A view directory on the same underlying filesystem as `/nix/store`**,
   for example `/nix/var/ate/views`. Views are made of hard links.
3. **A non-recursive, private bind of `/nix` at `/var/lib/ate-nix`**.
   Mount this alias into atelet as `/nix`, not the original host path.
   NixOS can bind `/nix/store` read-only beneath `/nix`; a recursive hostPath
   mount copies that child mount into the pod. The store and view directory
   then belong to different mount objects, so hard links fail with `EXDEV`
   even when their underlying filesystem is the same. The non-recursive
   alias excludes that child mount, and private propagation keeps later
   source-side child mounts out as well. A separately mounted store on a
   different underlying filesystem still cannot share hard-link views here.
4. **The view directory bind-mounted under `/var/lib/ate`**, for example at
   `/var/lib/ate/nix-views`. Worker pods mount only `/var/lib/ate` from the
   host, so this is how they see the views.

### On any distribution

`kind/node-setup.sh` does all four. Run it as root on the node. It expects a standard Nix installation in `/nix` and installs nothing.

```sh
SUBSTITUTERS="https://cache.nixos.org https://cache.example.com" \
TRUSTED_PUBLIC_KEYS="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= example-1:..." \
  sh kind/node-setup.sh
```

Without the two variables, the script trusts `cache.nixos.org` only.
The script is safe to run again. If the cache list or the key list changes, it restarts the daemon, because the daemon reads its configuration only when it starts.

The script starts the daemon with `systemd-run`, makes both bind mounts with
`mount --bind`, and makes `/var/lib/ate-nix` private. These changes do not
survive a reboot. For a long-lived node, configure a daemon unit and both
mounts in the node's own configuration. The alias must use `bind,private`,
never `rbind`; the view-directory bind remains unchanged.

### On NixOS

```nix
imports = [ inputs.ate-nix.nixosModules.ate-node ];

services.ate-node.nixImages = {
  enable = true;
  substituters = [ "https://cache.example.com" ];
  trustedPublicKeys = [ "example-1:..." ];
  # viewDir = "/nix/var/ate/views";        # default
  # mountDir = "/var/lib/ate/nix-views";   # default
};
```

The module creates the same non-recursive, private alias and view-directory
bind as the script, as persistent filesystem mounts. The DaemonSet must use
the alias hostPath described below, even on NixOS.

Before updating atelet, inspect the mount topology on each node:

```sh
findmnt --submounts --mountpoint /var/lib/ate-nix \
  --output TARGET,SOURCE,PROPAGATION
findmnt --mountpoint /var/lib/ate/nix-views --output TARGET,SOURCE
```

The first command should show a private alias mount, with **no child mount at
`/var/lib/ate-nix/store`**. The second should show the view-directory bind
(adjust its path if you changed `mountDir`). These checks establish the mount
topology, not actor correctness; the actor start/suspend/resume proof below
still needs to succeed.

## 2. Replace atelet and ateapi

These two components implement the Nix actor-image source. The portable
release also patches the shared worker overlay mount code; publish both worker
images from `ate-substrate.patchedSrc` when using older kernels, as described
above. A full portable release already contains the required atelet/ateapi
changes, so skip the image replacement if you installed that release.

| Component | Why it is patched |
| --- | --- |
| `atelet` | Builds the views. |
| `ateapi` | Accepts `nix:` references. The upstream one rejects them. |

Build the images and load them into your registry:

```sh
nix build .#atelet-image && docker load < result    # ate-nix/atelet:1.0.0
nix build .#ateapi-image && docker load < result    # ate-nix/ateapi:1.0.0
```

The images use the same layout as the upstream images (`/ko-app/<name>`), so only the image reference changes:

```sh
kubectl -n ate-system set image ds/atelet atelet=<registry>/ate-nix/atelet:1.0.0
kubectl -n ate-system set image deploy/ate-api-server ate-api-server=<registry>/ate-nix/ateapi:1.0.0
```

One difference from upstream: the atelet image has no C library. Upstream's has one so that atelet can run a dynamically linked kubelet credential provider for OCI pulls from a private registry (GKE Ubuntu, AKS). On such a node, pull OCI images from registries that need no credential provider, or build atelet on upstream's base image.

The overlayfs fallback runs in the **worker**, not atelet. Installing the
control plane does not rewrite existing WorkerPools. On an older kernel,
point each pool at the matching patched worker digest printed by the full OCI
publisher (choose `ateworker-microvm` for a microVM pool):

```sh
kubectl -n <atespace> patch workerpool <pool> --type=merge \
  -p '{"spec":{"workerImage":"registry.example.com/substrate/ateworker-gvisor@sha256:<published-digest>"}}'
```

Use the release's worker reference in new pool manifests as well. An
unpatched worker cannot gain the fallback by updating atelet or ateapi alone.

## 3. Give atelet the store

atelet needs the host's **`/var/lib/ate-nix` alias** mounted at container
`/nix`, and three arguments. Prepare the alias first; using a direct hostPath
of `/nix` reintroduces the NixOS read-only-child-mount hard-link failure.
The container paths do not change, so the daemon socket and `nix-store`
command remain accessible at their normal `/nix/...` paths:

| Argument | Value | Meaning |
| --- | --- | --- |
| `--nix-view-dir` | `/nix/var/ate/views` | Where atelet builds views. This argument enables Nix images. Without it, Nix images are off. |
| `--nix-view-mount-dir` | `/var/lib/ate/nix-views` | The path at which worker pods see the same directory. |
| `--nix-store-command` | `/nix/var/nix/profiles/default/bin/nix-store` | The `nix-store` program. On NixOS: `/nix/var/nix/profiles/system/sw/bin/nix-store`. |

`kind/atelet-nix.patch.json` is this change for the upstream DaemonSet:

```sh
kubectl -n ate-system patch ds atelet --type=json --patch-file kind/atelet-nix.patch.json
kubectl -n ate-system rollout status ds/atelet
```

atelet talks to the Nix daemon through the daemon's socket under `/nix/var/nix/daemon-socket`. It never writes to the store.

## Mixed clusters

A template with a Nix image that lands on a node without `--nix-view-dir` fails to start, and the error names the missing argument. If only some nodes have Nix, use a worker pool with a node selector and send Nix templates to that pool.

## Trust

- The node decides what to accept. A template cannot add a cache or a key.
- Trust is checked when a path is downloaded, not each time an actor starts. If you remove a key, paths that the node already has stay usable, and so do their views. To revoke an image, see the next section.
- With `require-sigs = true`, the daemon takes a path only if a key in `trusted-public-keys` signed it. An unsigned path and a path signed with an unknown key are both refused. [proof.md](proof.md) shows this test.
- Give the signing key to the system that builds images (CI), not to the nodes. Nodes need the public key only.
- A cache that needs a login is not tested. See [proof.md](proof.md).

## Revoke an image

Use this when an image, or a package inside images, must not run again: a leaked signing key, a bad build.

1. Stop the source. Remove the key from `trusted-public-keys` on each node and restart the Nix daemon, or delete the path from the cache. If you skip this step, the node downloads the path again on the next request.
2. On each node, run atelet one more time beside the running one. `--nix-revoke` makes it do one job and exit:

   ```sh
   kubectl -n ate-system exec <atelet pod on the node> -- /ko-app/atelet \
     --nix-view-dir=/nix/var/ate/views \
     --nix-store-command=/nix/var/nix/profiles/default/bin/nix-store \
     --nix-revoke=/nix/store/<hash>-<name>
   ```

   It removes each view that contains the path. Then it deletes the path, and each store path that depends on the path, from the node's store. If you revoke a package, all images on the node that contain the package go.
3. Delete the actors that run from a revoked image. Their files are gone.

After that, a request for the image is a new download, and the node applies its current trust rules. `kind/private-cache.sh` shows the full sequence.

If a store path that depends on the revoked path has another GC root (for example, a `result` link from a build on the node), Nix does not delete it. The views are removed, the command fails, and the error names the path. Remove the root and run the command again.

## Check that it works

Create a template from a path in the public cache and wait for its golden snapshot. `kind/prove.sh` does a full check: it starts an actor, compares what the actor sees with the closure, then suspends and resumes the actor. It expects the kind cluster of [../kind/README.md](../kind/README.md), but the template and pool files next to it (`kind/proof-template.yaml`, `kind/proof-pool.yaml`) work on any cluster.

For the portable installation, use your S3 snapshot location and the patched
worker digest in the pool manifest. The checked-in Kind pool's worker
reference is not automatically replaced by `ate-setup`; using an upstream
worker on an older kernel would not exercise the compatibility patch.

If a template does not reach its golden snapshot, see [troubleshooting.md](troubleshooting.md).
