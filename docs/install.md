# Install Substrate on your own cluster

Install Agent Substrate on a Kubernetes cluster that you already have and that is not GKE (Google Kubernetes Engine, the platform that the upstream installer assumes).
This page uses ordinary container images. It needs no Nix on the nodes, no Nix snapshotter and no NixOS.

- You only want to try the project: use the local cluster in [../kind/README.md](../kind/README.md) instead. It needs none of this page.
- Substrate is already installed: skip this page and go to [operating.md](operating.md) to enable Nix images.
- You want Substrate's own pods to come from a Nix cache, with no registry: see [nix-images.md](nix-images.md#registry-free-substrate-system-pods).

The steps, in order: check the cluster, publish the patched images, create snapshot storage, deploy, check.

All commands use the installer from this repository:

```sh
ATE_PACKAGE="$(nix build --no-link --print-out-paths .#ate-substrate)"
```

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
IMAGE_TAG=v1.0.1-ate-nix
BUILD_DIR="$(mktemp -d)"

# Publish from a writable copy, retaining every manifest, .ko.yaml, ko module,
# Dockerfile, ko-data directory, and worker source from the same patched pin.
cp -R "$PATCHED_SRC/." "$BUILD_DIR/"
chmod -R u+w "$BUILD_DIR"

# The fetched Nix source has no .git. Upstream's release publisher requires
# provenance from a real commit; this records the full patched snapshot.
git -C "$BUILD_DIR" init --initial-branch=build
git -C "$BUILD_DIR" add --force --all
git -C "$BUILD_DIR" commit -m "Snapshot ate-nix patched Substrate v1.0.1"

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
  tag: v1.0.1-ate-nix
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
durability or that your CNI supports actor traffic.

## Next

To let actors start from Nix store paths on this cluster, continue with
[operating.md](operating.md). A release published from this page already has
the patched `atelet` and `ateapi`, so step 2 there does not apply.
