{
  lib,
  buildGoModule,
  fetchFromGitHub,
  applyPatches,
  makeBinaryWrapper,
  bashInteractive,
  git,
  stdenv,
}:

let
  version = "1.0.1";
  patchedSrc = applyPatches {
    name = "ate-substrate-${version}-src";
    src = fetchFromGitHub {
      owner = "agent-substrate";
      repo = "substrate";
      rev = "20778a6dbb01f13024642851bb592bf67c9fec05"; # v1.0.1
      hash = "sha256-8qZR+bOdCLEMBMFID/XQmZ7LwkyZUlRmHIsdSYd2q6k=";
    };
    patches = [
      ../patches/substrate/0001-atelet-nix-image-source.patch
      ../patches/substrate/0002-existing-cluster-installer.patch
      ../patches/substrate/0003-overlayfs-legacy-fallback.patch
      ../patches/substrate/0009-ate-setup-image-map.patch
    ];
  };
in
buildGoModule {
  pname = "ate-substrate";
  inherit version;
  src = patchedSrc;

  # A release publisher can build the complete OCI image set from exactly the
  # same patched source, including worker binaries that consume imagecache.
  passthru = { inherit patchedSrc; };

  # Upstream commits its vendor directory.
  vendorHash = null;

  subPackages = [
    "cmd/atelet"
    "cmd/ateapi"
    "cmd/ate-setup"
    "cmd/kubectl-ate"
  ];

  nativeBuildInputs = [ makeBinaryWrapper ];
  nativeCheckInputs = [
    bashInteractive
    git
  ];

  # The installer reads manifests, demo templates, and helper resources from
  # this pinned tree. Do not chdir: relative config/kubeconfig paths must keep
  # resolving against the operator's directory. Prebuilt-image deploys need
  # neither Go/ko nor Docker; source publishing needs those tools on PATH.
  postInstall = ''
    wrapProgram "$out/bin/ate-setup" \
      --set-default ATE_SOURCE_ROOT "${patchedSrc}"
  '';

  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];

  # Keep the original Nix-image tests and exercise the installer with its real
  # manifests. Privileged overlay/worker runtime tests are separate Linux
  # operator checks; the option encoder itself runs in the build sandbox.
  checkPhase = ''
    runHook preCheck
    # Upstream's release-publishing regression test requires a real checked-out
    # commit and builds kubectl-ate with its stamp. Record this exact sandbox
    # source as a temporary Git snapshot rather than weakening that test.
    git init --initial-branch=build
    git add --force --all
    git -c user.name="ate-nix build" -c user.email="build@localhost" \
      -c commit.gpgSign=false commit --quiet -m "Patched Substrate build source"
    go test ./internal/niximage/... ./internal/nixref/... ./internal/resources/... \
      ./cmd/ate-setup/internal/config/... ./cmd/ate-setup/internal/images/... \
      ./cmd/ate-setup/internal/steps/...
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      go test ./internal/imagecache -run '^TestLegacyOverlayOptions'
    ''}
    runHook postCheck
  '';

  meta = {
    description = "Agent Substrate with Nix actor images and portable Kubernetes deployment tools";
    homepage = "https://github.com/agent-substrate/substrate";
    license = lib.licenses.asl20;
    mainProgram = "atelet";
  };
}
