# kagent (https://kagent.dev) runs its agents as Agent Substrate actors, on its
# own Substrate fork. These are the pieces that let a kagent Agent boot from a
# Nix store path: kagent with patches/kagent applied, that fork with the same
# patches/substrate as `ate-substrate`, and a Nix image of kagent's agent
# runtime. docs/kagent.md has the steps and what was seen to work.
{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  applyPatches,
  dockerTools,
  runCommand,
  writeTextDir,
  bashInteractive,
  cacert,
  coreutils,
  ateNixImage,
  ateImages,
}:

let
  version = "1.0.1";
  rev = "558e3d761d8ed2b0d23bfef1867a9d1915210121"; # v1.0.1
  # The Substrate fork release that kagent ${version} installs.
  substrateVersion = "1.0.0";

  versionPackage = "github.com/kagent-dev/kagent/go/core/internal/version";

  kagent = buildGoModule {
    pname = "kagent";
    inherit version;
    src = applyPatches {
      name = "kagent-${version}-src";
      src = fetchFromGitHub {
        owner = "kagent-dev";
        repo = "kagent";
        inherit rev;
        hash = "sha256-u4LWk2PI5OtnCCKEl1WYFWcf2MTC3MSTe3vnIdGsAlA=";
      };
      patches = [ ../patches/kagent/0001-accept-nix-store-path-images.patch ];
    };

    modRoot = "go";
    vendorHash = "sha256-AhxLooGnVlJTyuPfTDSPAjsRWcnYWE7nM4F1RfXwI8w=";

    subPackages = [
      "core/cmd/controller"
      "adk/cmd"
    ];

    env.CGO_ENABLED = 0;
    # The controller refuses to start when its release does not match the
    # release of the built-in Harness images, so an unstamped build ("dev")
    # crash-loops in a ${version} install.
    ldflags = [
      "-s"
      "-w"
      "-X ${versionPackage}.Version=${version}"
      "-X ${versionPackage}.GitCommit=${builtins.substring 0 7 rev}-nix"
      "-X ${versionPackage}.SubstrateVersion=${substrateVersion}"
    ];

    checkPhase = ''
      runHook preCheck
      go test ./core/internal/image/...
      runHook postCheck
    '';

    postInstall = ''
      mv $out/bin/controller $out/bin/kagent-controller
      mv $out/bin/cmd $out/bin/kagent-adk
    '';

    meta = {
      description = "kagent controller and agent runtime that accept Nix store-path images";
      homepage = "https://github.com/kagent-dev/kagent";
      license = lib.licenses.asl20;
      mainProgram = "kagent-controller";
    };
  };

  substrate = buildGoModule {
    pname = "kagent-substrate";
    version = substrateVersion;
    src = applyPatches {
      name = "kagent-substrate-${substrateVersion}-src";
      src = fetchFromGitHub {
        owner = "kagent-dev";
        repo = "substrate";
        rev = "563df06f6be751c101539986896c17c55aa22a9d"; # v1.0.0
        hash = "sha256-I2gHCDfzISa7jfJCvI77wvlXmR/4vbsHqbt4wK9ivFk=";
      };
      patches = [
        ../patches/substrate/0001-atelet-nix-image-source.patch
        ../patches/substrate/0002-existing-cluster-installer.patch
        ../patches/substrate/0003-overlayfs-legacy-fallback.patch
        ../patches/substrate/0009-ate-setup-image-map.patch
      ];
    };

    # The fork commits its vendor directory, as upstream does.
    vendorHash = null;

    subPackages = [
      "cmd/atelet"
      "cmd/ateapi"
    ];

    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
    ];

    checkPhase = ''
      runHook preCheck
      go test ./internal/niximage/... ./internal/nixref/...
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        go test ./internal/imagecache -run '^TestLegacyOverlayOptions'
      ''}
      runHook postCheck
    '';

    meta = {
      description = "atelet and ateapi of kagent's Substrate fork, with Nix actor images";
      homepage = "https://github.com/kagent-dev/substrate";
      license = lib.licenses.asl20;
      mainProgram = "atelet";
    };
  };
in
{
  inherit kagent substrate;

  # Same layout as the fork's own images, so only the image reference changes
  # in a kagent install.
  ateletImage = ateImages.mkImage {
    name = "kagent-atelet";
    package = substrate;
    binary = "atelet";
    user = "0:0";
  };
  ateapiImage = ateImages.mkImage {
    name = "kagent-ateapi";
    package = substrate;
    binary = "ateapi";
    user = "65532:65532";
  };

  # Laid out like kagent's controller image: the binary is /app.
  controllerImage = dockerTools.buildLayeredImage {
    name = "ate-nix/kagent-controller";
    tag = version;

    extraCommands = ''
      mkdir -p etc/ssl/certs tmp
      chmod 1777 tmp
      cp ${kagent}/bin/kagent-controller app
      cp ${cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      cat > etc/passwd <<EOF
      root:x:0:0:root:/root:/sbin/nologin
      kagent:x:65532:65532:kagent:/tmp:/sbin/nologin
      EOF
      cat > etc/group <<EOF
      root:x:0:
      kagent:x:65532:
      EOF
    '';

    config = {
      Entrypoint = [ "/app" ];
      User = "65532:65532";
      Env = [
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        "HOME=/tmp"
      ];
    };
  };

  # kagent's agent runtime as a Nix actor image, for a Harness:
  # `workload.image: nix:${result}` with `args: ["--filepath=/tmp/config"]`.
  # The runtime writes its agent config under /config by default, and the
  # actor's user cannot create a directory in the root of a store-path image.
  adkImage = ateNixImage {
    name = "kagent-adk-nix-image";
    paths = [
      (runCommand "kagent-adk-${version}" { } ''
        install -Dm755 ${kagent}/bin/kagent-adk $out/app
      '')
      bashInteractive
      coreutils
      cacert
      (writeTextDir "etc/passwd" ''
        root:x:0:0:root:/root:/bin/bash
        kagent:x:65532:65532:kagent:/tmp:/bin/bash
      '')
      (writeTextDir "etc/group" ''
        root:x:0:
        kagent:x:65532:
      '')
    ];
    config = {
      Entrypoint = [ "/app" ];
      User = "65532:65532";
      Env = [
        "PATH=/bin"
        "HOME=/tmp"
      ];
    };
  };
}
